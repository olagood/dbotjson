%%%-------------------------------------------------------------------
%%% Copyright (C) 2020 drastik.org
%%%
%%% This file is part of dbotjson.
%%%
%%% This program is free software: you can redistribute it and/or modify
%%% it under the terms of the GNU Affero General Public License as published
%%% by the Free Software Foundation, version 3 only.
%%%
%%% This program is distributed in the hope that it will be useful,
%%% but WITHOUT ANY WARRANTY; without even the implied warranty of
%%% MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
%%% GNU Affero General Public License for more details.
%%%
%%% You should have received a copy of the GNU Affero General Public License
%%% along with this program.  If not, see <https://www.gnu.org/licenses/>.
%%%-------------------------------------------------------------------

%%%-------------------------------------------------------------------
%%% @author drastik <derezzed@protonmail.com>
%%% @copyright (C) 2020, drastik.org
%%% Created : 7 Jul 2020 by drastik <derezzed@protonmail.com>
%%%-------------------------------------------------------------------

%%%-------------------------------------------------------------------
%%% @doc
%%% Parse JSON text conforming to the RFC 8259 standard.
%%%
%%% The parser is UTF-8 (and consequently ASCII) compatible only.
%%% Modifying it to support other unicode encodings should be easy.
%%%
%%% WARNING: This parser does not have a depth limiter.
%%%
%%% The JSON values are decoded as follows:
%%% Objects {} -> Maps #{}
%%% Arrays  [] -> Lists []
%%% Numbers    -> Integers or Floats
%%% Strings    -> Binaries
%%% Booleans   -> Atoms: true | false
%%% Null       -> Atom: null
%%%
%%% The decoding interfaces provided by this module are:
%%% decode/1 which will decode the entire JSON text given.
%%% get/2 is based on an idea from http://verisimilitudes.net and will
%%% essentially avoid all unnecessary allocations/decoding by skipping
%%% the JSON text until the specified path is found. This also has the
%%% effect of allowing processing of broken/invalid JSON so long as
%%% the issue did not occur before the desired object.
%%%
%%% Example:
%%% Given the following JSON text: {"test": [1, 2, 3, 4, 5]}
%%% J = <<"{\"test\": [1, 2, 3, 4, 5]}">>
%%%
%%% The function decode/1 called as dbotjson:decode(J) would return:
%%% #{<<"test">> => [1, 2, 3, 4, 5]}.
%%%
%%% If we wanted to get the 4th item of the array without decoding the
%%% whole string we can call the function get/2 as follows:
%%% dbotjson:get([<<"test">>, 4], J)
%%% @end
%%%-------------------------------------------------------------------

-module(dbotjson).

-export([decode/1, get/2]).


-define(IS_WS(C), C =:= $\s; C =:= $\r; C =:= $\n; C =:= $\t).
-define(IS_HEX(C), C >= $0, C =< $9; C >= $A, C =< $F; C >= $a, C =< $f).

-define(IS_UTF8(C1), C1 < 128).
-define(IS_UTF8(C1, C2),
        C1 >= 194, C1 =< 223,
        C2 >= 128, C2 =< 191).
-define(IS_UTF8(C1, C2, C3),
        C1 >= 224, C1 =< 239,
        C2 >= 128, C2 =< 191,
        C3 >= 128, C3 =< 191).
-define(IS_UTF8(C1, C2, C3, C4),
        C1 >= 240, C1 =< 244,
        C2 >= 128, C2 =< 191,
        C3 >= 128, C3 =< 191,
        C4 >= 128, C4 =< 191).


%%% Type Declarations
-type jvalue() :: jobject() | jarray() | jstring()
                | jnumber() | jboolean() | jnull().
-type jobject() :: #{jstring() := jvalue()}.
-type jarray() :: [jvalue()].
-type jstring() :: binary().
-type jnumber() :: integer() | float().
-type jboolean() :: true | false.
-type jnull() :: null.


%%--------------------------------------------------------------------
%% @param Bin A binary that contains the JSON text to be decoded.
%% @returns The corresponding erlang term of the JSON text.
%% @throws {invalid, Pos} when the JSON text given is erroneous.
%% @doc
%% Decode JSON text to erlang data types.
%% @end
%%--------------------------------------------------------------------
-spec decode(Bin :: binary()) -> jvalue().
decode(Bin) ->
    {Res, _Pos} = decode_value(Bin, 0),
    Res.


%%--------------------------------------------------------------------
%% @param Path A list of the object names and array indexes that
%% must be skipped before decoding starts.
%% @param Bin A binary that contains the JSON text.
%% @returns {ok, jvalue()} if the value is found, {error, Pos} if the
%% path given does not lead to a JSON value. Pos is the index of the
%% last character visited.
%% @throws {invalid, Pos} if there is any problem with the JSON text.
%% @doc
%% Walk the Path given skipping all JSON values and decode only the
%% value pointed at by the last item of the Path.
%% @end
%%--------------------------------------------------------------------
-spec get(Path :: [binary() | integer()], Bin :: binary()) ->
          {ok, jvalue()} | {error, integer()}.
get(Path, Bin) ->
     case skip_value(Bin, 0, Path, []) of
         {Res, _Pos} ->  % Result Found
             {ok, Res};
         Pos ->
             {error, Pos}
     end.


%%%===================================================================
%%% Decoding Interface
%%%===================================================================

%%% Value Dispatcher

-spec decode_value(Bin :: binary(), Pos :: integer()) ->
          {Object :: jobject(), Pos :: integer()} |
          {Array :: jarray(), Pos :: integer()} |
          {String :: jstring(), Pos :: integer()} |
          {Number :: jnumber(), Pos :: integer()} |
          {Boolean :: jboolean(), Pos :: integer()} |
          {Null :: jnull(), Pos :: integer()}.
decode_value(Bin, Pos) ->
    case Bin of
        <<_:Pos/binary, C, _/binary>> when ?IS_WS(C) ->
            decode_value(Bin, Pos + 1);
        <<_:Pos/binary, C, R/binary>> when C >= $1, C =< $9 ->
            decode_number_integer(R, Pos + 1, [C]);
        <<_:Pos/binary, $", R/binary>> ->
            decode_string(R, Pos + 1);
        <<_:Pos/binary, ${, _/binary>> ->
            decode_object(Bin, Pos + 1);
        <<_:Pos/binary, $[, _/binary>> ->
            decode_array(Bin, Pos + 1);
        <<_:Pos/binary, $-, R/binary>> ->
            decode_number_minus(R, Pos + 1, [$-]);
        <<_:Pos/binary, $0, R/binary>> ->
            decode_number_zero(R, Pos + 1, [$0]);
        <<_:Pos/binary, "true", _/binary>> ->
            {true, Pos + 4};
        <<_:Pos/binary, "false", _/binary>> ->
            {false, Pos + 5};
        <<_:Pos/binary, "null", _/binary>> ->
            {null, Pos + 4};
        _Else ->
            throw({invalid, Pos})
    end.


%%% Objects

-spec decode_object(Bin :: binary(), Pos :: integer()) ->
          {Value :: jobject(), Pos :: integer()}.
decode_object(Bin, Pos) ->
    case Bin of
        <<_:Pos/binary, C, _/binary>> when ?IS_WS(C) ->
            decode_object(Bin, Pos + 1);
        <<_:Pos/binary, $}, _/binary>> ->
            {#{}, Pos + 1};
        <<_:Pos/binary, $", R/binary>> ->
            {Name, NPos} = decode_string(R, Pos + 1),
            decode_object_value(Bin, NPos, Name, #{});
        _Else ->
            throw({invalid, Pos})
        end.

decode_object_value(Bin, Pos, Name, Acc) ->
    case Bin of
        <<_:Pos/binary, C, _/binary>> when ?IS_WS(C) ->
            decode_object_value(Bin, Pos + 1, Name, Acc);
        <<_:Pos/binary, $:, _/binary>> ->
            {Value, NPos} = decode_value(Bin, Pos + 1),
            decode_object_next(Bin, NPos, Acc#{Name => Value});
        _Else ->
            throw({invalid, Pos})
    end.

decode_object_next(Bin, Pos, Acc) ->
    case Bin of
        <<_:Pos/binary, C, _/binary>> when ?IS_WS(C) ->
            decode_object_next(Bin, Pos + 1, Acc);
        <<_:Pos/binary, $,, _/binary>> ->
            decode_object_next_name(Bin, Pos + 1, Acc);
        <<_:Pos/binary, $}, _/binary>> ->
            {Acc, Pos + 1};
        _Else ->
            throw({invalid, Pos})
    end.

decode_object_next_name(Bin, Pos, Acc) ->
    case Bin of
        <<_:Pos/binary, C, _/binary>> when ?IS_WS(C) ->
            decode_object_next_name(Bin, Pos + 1, Acc);
        <<_:Pos/binary, $", R/binary>> ->
            {Name, NPos} = decode_string(R, Pos + 1),
            decode_object_value(Bin, NPos, Name, Acc);
        _Else ->
            throw({invalid, Pos})
    end.


%%% Arrays

-spec decode_array(Bin :: binary(), Pos :: integer()) ->
          {Value :: jarray(), Pos :: integer()}.
decode_array(Bin, Pos) ->
    case Bin of
        <<_:Pos/binary, C, _/binary>> when ?IS_WS(C) ->
            decode_array(Bin, Pos + 1);
        <<_:Pos/binary, $], _/binary>> ->
            {[], Pos + 1};
        _Else ->
            {Value, NPos} = decode_value(Bin, Pos),
            decode_array_value(Bin, NPos, [Value])
    end.

decode_array_value(Bin, Pos, Acc) ->
    case Bin of
        <<_:Pos/binary, C, _/binary>> when ?IS_WS(C) ->
            decode_array_value(Bin, Pos + 1, Acc);
        <<_:Pos/binary, $,, _/binary>> ->
            {Value, NPos} = decode_value(Bin, Pos + 1),
            decode_array_value(Bin, NPos, [Value | Acc]);
        <<_:Pos/binary, $], _/binary>> ->
            {lists:reverse(Acc), Pos + 1};
        _Else ->
            throw({invalid, Pos})
    end.


%%% Numbers

-spec decode_number_minus(binary(), Pos :: integer(), Acc :: list()) ->
          {Value :: jnumber(), Pos :: integer()}.
decode_number_minus(<<$0, R/binary>>, Pos, Acc) ->
    decode_number_zero(R, Pos + 1, [$0 | Acc]);
decode_number_minus(<<C, R/binary>>, Pos, Acc) when C >= $1, C =< $9 ->
    decode_number_integer(R, Pos + 1, [$0 | Acc]);
decode_number_minus(_Else, Pos, _Acc) ->
    throw({invalid, Pos}).

-spec decode_number_zero(binary(), Pos :: integer(), Acc :: list()) ->
          {Value :: jnumber(), Pos :: integer()}.
decode_number_zero(<<$., R/binary>>, Pos, Acc) ->
    decode_number_fractional(R, Pos + 1, [$. | Acc]);
decode_number_zero(<<C, R/binary>>, Pos, Acc) when C == $e; C == $E ->
    decode_number_exponent(R, Pos + 1, [$e, $0, $. | Acc]);
decode_number_zero(_Rest, Pos, _Acc) ->
    {0, Pos}.

-spec decode_number_integer(binary(), Pos :: integer(), Acc :: list()) ->
          {Value :: jnumber(), Pos :: integer()}.
decode_number_integer(<<C, R/binary>>, Pos, Acc) when C >= $0, C =< $9 ->
    decode_number_integer(R, Pos + 1, [C | Acc]);
decode_number_integer(<<$., R/binary>>, Pos, Acc) ->
    decode_number_fractional(R, Pos + 1, [$. | Acc]);
decode_number_integer(<<C, R/binary>>, Pos, Acc) when C =:= $e; C =:= $E ->
    decode_number_exponent(R, Pos + 1, [$e, $0, $. | Acc]);
decode_number_integer(_Rest, Pos, Acc) ->
    {list_to_integer(lists:reverse(Acc)), Pos}.

decode_number_fractional(<<C, R/binary>>, Pos, Acc) when C >= $0, C =< $9 ->
    decode_number_fractional(R, Pos + 1, [C | Acc]);
decode_number_fractional(<<C, R/binary>>, Pos, Acc) when C =:= $e; C =:= $E ->
    decode_number_exponent(R, Pos + 1, [$e | Acc]);
decode_number_fractional(_Rest, Pos, Acc) ->
    {list_to_float(lists:reverse(Acc)), Pos}.

decode_number_exponent(<<$+, R/binary>>, Pos, Acc) ->
    decode_number_exponent_digit(R, Pos + 1, [$+ | Acc]);
decode_number_exponent(<<$-, R/binary>>, Pos, Acc) ->
    decode_number_exponent_digit(R, Pos + 1, [$- | Acc]);
decode_number_exponent(<<C, R/binary>>, Pos, Acc) when C >= $0, C =< $9 ->
    decode_number_exponent_digit(R, Pos + 1, [C | Acc]);
decode_number_exponent(_Rest, Pos, _Acc) ->
    throw({invalid, Pos}).

decode_number_exponent_digit(<<C, R/binary>>, Pos, Acc) when C >= $0, C =< $9 ->
    decode_number_exponent_digit(R, Pos + 1, [C | Acc]);
decode_number_exponent_digit(_Rest, Pos, Acc) ->
    {list_to_float(lists:reverse(Acc)), Pos}.


%%% Strings

%%--------------------------------------------------------------------
%% @private
%% @doc
%% JSON string parser. It reads one byte at a time. It should be fast
%% against UTF-8 strings that contain a small number of 2-4 code unit
%% characters. If only 1 code unit characters are present (ASCII)
%% then this is the fastest string parser provided.
%% @end
%%--------------------------------------------------------------------
-spec decode_string(binary(), Pos :: integer()) ->
          {Value :: binary(), Pos :: integer()}.
decode_string(<<Bin/binary>>, Pos) ->
    case decode_string_parse(Bin, Pos) of
        {esc, SPos} ->
            <<S:(SPos - Pos)/binary, $\\, R/binary>> = Bin,
            L1 = lists:reverse(binary_to_list(S)),
            decode_string_escape(R, SPos + 1, L1);
        SPos ->
            <<S:(SPos - Pos)/binary, _/binary>> = Bin,
            {S, SPos + 1}
    end.

decode_string_parse(<<$", _/binary>>, Pos) ->
    Pos;
decode_string_parse(<<$\\, _/binary>>, Pos) ->
    {esc, Pos};
decode_string_parse(<<_, R/binary>>, Pos) ->
    decode_string_parse(R, Pos + 1);
decode_string_parse(<<>>, Pos) ->
    throw({invalid, Pos}).

decode_string_parse(<<$", _/binary>>, Pos, Acc) ->
    {list_to_binary(lists:reverse(Acc)), Pos + 1};
decode_string_parse(<<$\\, R/binary>>, Pos, Acc) ->
    decode_string_escape(R, Pos + 1, Acc);
decode_string_parse(<<C, R/binary>>, Pos, Acc) ->
    decode_string_parse(R, Pos + 1, [C | Acc]);
decode_string_parse(<<>>, Pos, _Acc) ->  % EOF
    throw({invalid, Pos}).

decode_string_escape(<<$", R/binary>>, Pos, Acc) ->
    decode_string_parse(R, Pos + 1, [$" | Acc]);
decode_string_escape(<<$\\, R/binary>>, Pos, Acc) ->
    decode_string_parse(R, Pos + 1, [$\\ | Acc]);
decode_string_escape(<<$/, R/binary>>, Pos, Acc) ->
    decode_string_parse(R, Pos + 1, [$/ | Acc]);
decode_string_escape(<<$b, R/binary>>, Pos, Acc) ->
    decode_string_parse(R, Pos + 1, [$\b | Acc]);
decode_string_escape(<<$f, R/binary>>, Pos, Acc) ->
    decode_string_parse(R, Pos + 1, [$\f | Acc]);
decode_string_escape(<<$n, R/binary>>, Pos, Acc) ->
    decode_string_parse(R, Pos + 1, [$\n | Acc]);
decode_string_escape(<<$r, R/binary>>, Pos, Acc) ->
    decode_string_parse(R, Pos + 1, [$\r | Acc]);
decode_string_escape(<<$t, R/binary>>, Pos, Acc) ->
    decode_string_parse(R, Pos + 1, [$\t | Acc]);
decode_string_escape(<<$u, D1, D2, D3, D4, R0/binary>>, Pos, Acc)
  when ?IS_HEX(D1), ?IS_HEX(D2), ?IS_HEX(D3), ?IS_HEX(D4) ->
    H = binary_to_integer(<<D1, D2, D3, D4>>, 16),
    if
        H > 16#D7FF, H < 16#DC00 ->  % UTF-16 high surrogate
            case R0 of
                <<$\\, $u, D5, D6, D7, D8, R1/binary>>
                  when ?IS_HEX(D5), ?IS_HEX(D6), ?IS_HEX(D7), ?IS_HEX(D8) ->
                    L = binary_to_integer(<<D5, D6, D7, D8>>, 16),
                    if
                        L > 16#DBFF, L < 16#E000 ->  % UTF-16 low surrogate
                            Code = codepoint_from_utf16_surrogates(H, L),
                            decode_string_parse(R1, Pos + 11,
                                                [<<Code/utf8>> | Acc]);
                        true ->  % Lone high surrogate
                            decode_string_parse(R0, Pos + 5, [$? | Acc])
                    end;
                _Else ->  % Lone high surrogate
                    decode_string_parse(R0, Pos + 5, [$? | Acc])
            end;
        true ->
            decode_string_parse(R0, Pos + 5, [<<H/utf8>> | Acc])
    end;
decode_string_escape(<<_/binary>>, Pos, _Acc) ->  % Invalid escape character
    throw({invalid, Pos}).


%%% Helper Functions

codepoint_from_utf16_surrogates(High, Low) ->
    H = (High - 16#D800) * 16#400,
    L = Low - 16#DC00,
    H + L + 16#10000.



%%%===================================================================
%%% Skipping Functions
%%%===================================================================

%%% Skip Value Dispatcher

skip_value(<<Bin/binary>>, Pos, [], _) ->  % When the Path is empty decode JSON
    decode_value(Bin, Pos);
skip_value(Bin, Pos, Path, Flag) ->
    case Bin of
        <<_:Pos/binary, C, _/binary>> when ?IS_WS(C) ->
            skip_value(Bin, Pos + 1, Path, Flag);
        <<_:Pos/binary, C, R/binary>> when C >= $1, C =< $9 ->
            skip_number_integer(R, Pos + 1);
        <<_:Pos/binary, $", R/binary>> ->
            skip_string(R, Pos + 1);
        <<_:Pos/binary, ${, _/binary>> ->
            skip_object(Bin, Pos + 1, Path, Flag);
        <<_:Pos/binary, $[, _/binary>> ->
            skip_array(Bin, Pos + 1, 1, Path, Flag);
        <<_:Pos/binary, $-, R/binary>> ->
            skip_number_minus(R, Pos + 1);
        <<_:Pos/binary, $0, R/binary>> ->
            skip_number_zero(R, Pos + 1);
        <<_:Pos/binary, "true", _/binary>> ->
            Pos + 4;
        <<_:Pos/binary, "false", _/binary>> ->
            Pos + 5;
        <<_:Pos/binary, "null", _/binary>> ->
            Pos + 4;
        _Else ->
            throw({invalid, Pos})
    end.


%%% Skip Objects

skip_object(<<Bin/binary>>, Pos, [HP | RP] = Path, Flag) ->
    case Bin of
        <<_:Pos/binary, C, _/binary>> when ?IS_WS(C) ->
            skip_object(Bin, Pos + 1, Path, Flag);
        <<_:Pos/binary, $}, _/binary>> ->
            Pos + 1;
        <<_:Pos/binary, $", R/binary>> ->
            case Flag of
                skip ->
                    NPos = skip_string(R, Pos + 1),
                    skip_object_value(Bin, NPos, Path, skip);
                _Else ->
                    {Name, NPos} = decode_string(R, Pos + 1),
                    if
                        Name =:= HP ->
                            skip_object_value(Bin, NPos, RP, []);
                        true ->
                            skip_object_value(Bin, NPos, Path, next)
                    end
            end;
        _Else ->
            throw({invalid, Pos})
    end.

skip_object_value(Bin, Pos, Path, Flag) ->
    case Bin of
        <<_:Pos/binary, C, _/binary>> when ?IS_WS(C) ->
            skip_object_value(Bin, Pos + 1, Path, Flag);
        <<_:Pos/binary, $:, _/binary>> ->
            case Flag of
                skip ->
                    NPos = skip_value(Bin, Pos + 1, Path, skip),
                    skip_object_next(Bin, NPos, Path, skip);
                next ->
                    NPos = skip_value(Bin, Pos + 1, Path, skip),
                    skip_object_next(Bin, NPos, Path, []);
                _Else ->
                    case Path of
                        [_ | _] ->
                            skip_value(Bin, Pos + 1, Path, []);
                        [] ->
                            decode_value(Bin, Pos + 1)
                    end
            end;
        _Else ->
            throw({invalid, Pos})
    end.

skip_object_next(Bin, Pos, Path, Flag) ->
    case Bin of
        <<_:Pos/binary, C, _/binary>> when ?IS_WS(C) ->
            skip_object_next(Bin, Pos + 1, Path, Flag);
        <<_:Pos/binary, $,, _/binary>> ->
            case Flag of
                skip ->
                    skip_object_next_name(Bin, Pos + 1, Path, skip);
                _Else ->
                    skip_object_next_name(Bin, Pos + 1, Path, [])
            end;
        <<_:Pos/binary, $}, _/binary>> ->
            Pos + 1;
        _Else ->
            throw({invalid, Pos})
    end.

skip_object_next_name(<<Bin/binary>>, Pos, [HP | RP] = Path, Flag) ->
    case Bin of
        <<_:Pos/binary, C, _/binary>> when ?IS_WS(C) ->
            skip_object_next_name(Bin, Pos + 1, Path, Flag);
        <<_:Pos/binary, $", R/binary>> ->
            case Flag of
                skip ->
                    NPos = skip_string(R, Pos + 1),
                    skip_object_value(Bin, NPos, Path, skip);
                _Else ->
                    {Name, NPos} = decode_string(R, Pos + 1),
                    if
                        Name =:= HP ->
                            skip_object_value(Bin, NPos, RP, []);
                        true ->
                            skip_object_value(Bin, NPos, Path, next)
                    end
            end;
        _Else ->
            throw({invalid, Pos})
    end.


%%% Skip Arrays

skip_array(<<Bin/binary>>, Pos, Index, [HP | RP] = Path, Flag) ->
    case Bin of
        <<_:Pos/binary, C, _/binary>> when ?IS_WS(C) ->
            skip_array(Bin, Pos + 1, Index, Path, Flag);
        <<_:Pos/binary, $], _/binary>> ->
            Pos + 1;
        _ ->
            case Flag of
                skip ->
                    NPos = skip_value(Bin, Pos, Path, skip),
                    skip_array_value(Bin, NPos, Index + 1, Path, skip);
                _Else ->
                    if
                        Index =:= HP ->
                            skip_value(Bin, Pos, RP, []);
                        true ->
                            NPos = skip_value(Bin, Pos, Path, skip),
                            skip_array_value(Bin, NPos, Index + 1, Path, [])
                    end
            end
    end.

skip_array_value(<<Bin/binary>>, Pos, Index, [HP | RP] = Path, Flag) ->
    case Bin of
        <<_:Pos/binary, C, _/binary>> when ?IS_WS(C) ->
            skip_array_value(Bin, Pos + 1, Index, Path, Flag);
        <<_:Pos/binary, $,, _/binary>> ->
            case Flag of
                skip ->
                    NPos = skip_value(Bin, Pos + 1, Path, skip),
                    skip_array_value(Bin, NPos, Index + 1, Path, skip);
                _Else ->
                    if
                        Index =:= HP ->
                            skip_value(Bin, Pos + 1, RP, []);
                        true ->
                            NPos = skip_value(Bin, Pos + 1, Path, skip),
                            skip_array_value(Bin, NPos, Index + 1, Path, [])
                    end
            end;
        <<_:Pos/binary, $], _/binary>> ->
            Pos + 1;
        _Else ->
            throw({invalid, Pos})
    end.


%%% Skip Numbers

skip_number_minus(<<$0, R/binary>>, Pos) ->
    skip_number_zero(R, Pos + 1);
skip_number_minus(<<C, R/binary>>, Pos) when C >= $1, C =< $9 ->
    skip_number_integer(R, Pos + 1);
skip_number_minus(_Else, Pos) ->
    throw({invalid, Pos}).

skip_number_zero(<<$., R/binary>>, Pos) ->
    skip_number_fractional(R, Pos + 1);
skip_number_zero(<<C, R/binary>>, Pos) when C == $e; C == $E ->
    skip_number_exponent(R, Pos + 1);
skip_number_zero(_Rest, Pos) ->
    Pos.

skip_number_integer(<<C, R/binary>>, Pos) when C >= $0, C =< $9 ->
    skip_number_integer(R, Pos + 1);
skip_number_integer(<<$., R/binary>>, Pos) ->
    skip_number_fractional(R, Pos + 1);
skip_number_integer(<<C, R/binary>>, Pos) when C =:= $e; C =:= $E ->
    skip_number_exponent(R, Pos + 1);
skip_number_integer(_Rest, Pos) ->
    Pos.

skip_number_fractional(<<C, R/binary>>, Pos) when C >= $0, C =< $9 ->
    skip_number_fractional(R, Pos + 1);
skip_number_fractional(<<C, R/binary>>, Pos) when C =:= $e; C =:= $E ->
    skip_number_exponent(R, Pos + 1);
skip_number_fractional(_Rest, Pos) ->
    Pos.

skip_number_exponent(<<$+, R/binary>>, Pos) ->
    skip_number_exponent_digit(R, Pos + 1);
skip_number_exponent(<<$-, R/binary>>, Pos) ->
    skip_number_exponent_digit(R, Pos + 1);
skip_number_exponent(<<C, R/binary>>, Pos) when C >= $0, C =< $9 ->
    skip_number_exponent_digit(R, Pos + 1);
skip_number_exponent(_Rest, Pos) ->
    throw({invalid, Pos}).

skip_number_exponent_digit(<<C, R/binary>>, Pos) when C >= $0, C =< $9 ->
    skip_number_exponent_digit(R, Pos + 1);
skip_number_exponent_digit(_Rest, Pos) ->
    Pos.


%%% Skip Strings

skip_string(<<$", _/binary>>, Pos) ->
    Pos + 1;
skip_string(<<$\\, $", R/binary>>, Pos) ->
    skip_string(R, Pos + 2);
skip_string(<<_, R/binary>>, Pos) ->
    skip_string(R, Pos + 1);
skip_string(<<>>, Pos) ->
    throw({invalid, Pos}).
