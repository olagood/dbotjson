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
%%% An implementation of the JSON object parser that decodes to
%%% property lists. The resulting term is {object, Proplist}. Decoding
%%% to property lists allows the user to access duplicate objects (The
%%% default maps based interface only keeps the last object.)
%%% @end
%%% Created : 15 Jul 2020 by drastik <derezzed@protonmail.com>
%%%-------------------------------------------------------------------

decode_object(Bin, Pos) ->
    case Bin of
        <<_:Pos/binary, C, _/binary>> when ?IS_WS(C) ->
            decode_object(Bin, Pos + 1);
        <<_:Pos/binary, $}, _/binary>> ->
            {{object, []}, Pos + 1};
        <<_:Pos/binary, $", R/binary>> ->
            {Name, NPos} = decode_string(R, Pos + 1),
            decode_object_value(Bin, NPos, Name, []);
        _Else ->
            throw({invalid, Pos})
        end.

decode_object_value(Bin, Pos, Name, Acc) ->
    case Bin of
        <<_:Pos/binary, C, _/binary>> when ?IS_WS(C) ->
            decode_object_value(Bin, Pos + 1, Name, Acc);
        <<_:Pos/binary, $:, _/binary>> ->
            {Value, NPos} = decode_value(Bin, Pos + 1),
            decode_object_next(Bin, NPos, [{Name, Value} | Acc]);
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
            {{object, lists:reverse(Acc)}, Pos + 1};
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
