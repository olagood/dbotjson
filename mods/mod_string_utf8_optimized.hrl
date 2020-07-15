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
%%% @doc
%%% UTF-8 optimized JSON string parser. It reads upto 4 bytes per
%%% iteration. It is faster against long UTF-8 strings with chatacters
%%% that consist of 2-4 code units. If the JSON string is purely ASCII
%%% text this will introduce an insignificant overhead.
%%% @end
%%% Created : 15 Jul 2020 by drastik <derezzed@protonmail.com>
%%%-------------------------------------------------------------------

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
decode_string_parse(<<C1, R/binary>>, Pos)
  when ?IS_UTF8(C1) ->
    decode_string_parse(R, Pos + 1);
decode_string_parse(<<C1, C2, R/binary>>, Pos)
  when ?IS_UTF8(C1), ?IS_UTF8(C2) ->
    decode_string_parse(R, Pos + 2);
decode_string_parse(<<C1, C2, C3, R/binary>>, Pos)
  when ?IS_UTF8(C1), ?IS_UTF8(C2), ?IS_UTF8(C3) ->
    decode_string_parse(R, Pos + 3);
decode_string_parse(<<C1, C2, C3, C4, R/binary>>, Pos)
  when ?IS_UTF8(C1), ?IS_UTF8(C2), ?IS_UTF8(C3), ?IS_UTF8(C4) ->
    decode_string_parse(R, Pos + 4);
decode_string_parse(_Else, Pos) ->
    throw({invalid, Pos}).

decode_string_parse(<<$", _/binary>>, Pos, Acc) ->
    Ret = list_to_binary(lists:reverse(Acc)),
    {Ret, Pos + 1};
decode_string_parse(<<$\\, R/binary>>, Pos, Acc) ->
    decode_string_escape(R, Pos + 1, Acc);
decode_string_parse(<<C1, R/binary>>, Pos, Acc)
  when ?IS_UTF8(C1) ->
    decode_string_parse(R, Pos + 1, [C1 | Acc]);
decode_string_parse(<<C1, C2, R/binary>>, Pos, Acc)
  when ?IS_UTF8(C1), ?IS_UTF8(C2) ->
    decode_string_parse(R, Pos + 2, [C1, C2 | Acc]);
decode_string_parse(<<C1, C2, C3, R/binary>>, Pos, Acc)
  when ?IS_UTF8(C1), ?IS_UTF8(C2), ?IS_UTF8(C3) ->
    decode_string_parse(R, Pos + 3, [C1, C2, C3 | Acc]);
decode_string_parse(<<C1, C2, C3, C4, R/binary>>, Pos, Acc)
  when ?IS_UTF8(C1), ?IS_UTF8(C2), ?IS_UTF8(C3), ?IS_UTF8(C4) ->
    decode_string_parse(R, Pos + 4, [C1, C2, C3, C4 | Acc]);
decode_string_parse(_Else, Pos, _Acc) ->
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
