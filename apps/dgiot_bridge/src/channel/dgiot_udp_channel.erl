%%--------------------------------------------------------------------
%% Copyright (c) 2020-2021 DGIOT Technologies Co., Ltd. All Rights Reserved.
%%
%% Licensed under the Apache License, Version 2.0 (the "License");
%% you may not use this file except in compliance with the License.
%% You may obtain a copy of the License at
%%
%%     http://www.apache.org/licenses/LICENSE-2.0
%%
%% Unless required by applicable law or agreed to in writing, software
%% distributed under the License is distributed on an "AS IS" BASIS,
%% WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
%% See the License for the specific language governing permissions and
%% limitations under the License.
%%--------------------------------------------------------------------

-module(dgiot_udp_channel).
-behavior(dgiot_channelx).
-include_lib("dgiot/include/logger.hrl").
-include("dgiot_bridge.hrl").
-define(TYPE, <<"UDP">>).
-author("kenneth").
-record(state, {id, ip, port, transport, env, product, log}).
%% API
-export([start/2]).
-export([init/3, handle_event/3, handle_message/2, stop/3]).
-export([start_link/3, do_init/1, handle_cast/2, handle_call/3, handle_info/2, terminate/2, code_change/3]).
-define(SOCKOPTS, [binary, {reuseaddr, true}]).


%% 注册通道类型
-channel_type(#{
    cType => ?TYPE,
    type => ?PROTOCOL_CHL,
    title => #{
        zh => <<"UDP采集通道"/utf8>>
    },
    description => #{
        zh => <<"UDP采集通道"/utf8>>
    }
}).
%% 注册通道参数
-params(#{
    <<"port">> => #{
        order => 1,
        type => integer,
        required => true,
        default => 3456,
        title => #{
            zh => <<"端口"/utf8>>
        },
        description => #{
            zh => <<"侦听端口"/utf8>>
        }
    },
    <<"ico">> => #{
        order => 102,
        type => string,
        required => false,
        default => <<"http://dgiot-1253666439.cos.ap-shanghai-fsi.myqcloud.com/shuwa_tech/zh/product/dgiot/channel/UdpIcon.png">>,
        title => #{
            en => <<"channel ICO">>,
            zh => <<"通道ICO"/utf8>>
        },
        description => #{
            en => <<"channel ICO">>,
            zh => <<"通道ICO"/utf8>>
        }
    }
}).

start(ChannelId, ChannelArgs) ->
    ok = esockd:start(),
    dgiot_channelx:add(?TYPE, ChannelId, ?MODULE, ChannelArgs).


%% 通道初始化
init(?TYPE, ChannelId, #{<<"port">> := Port} = _ChannelArgs) ->
    case dgiot_bridge:get_products(ChannelId) of
        {ok, ?TYPE, ProductIds} ->
            State = #state{
                id = ChannelId,
                env = #{},
                product = ProductIds
            },
            Name = dgiot_channelx:get_name(?TYPE, ChannelId),
            MFArgs = {?MODULE, start_link, [State]},
            ChildSpec = esockd:udp_child_spec(binary_to_atom(Name, utf8), Port, [{udp_options, ?SOCKOPTS}], MFArgs),
            {ok, State, ChildSpec};
        {error, not_find} ->
            {stop, not_find_product}
    end.


handle_event(EventType, Event, _State) ->
    ?LOG(info, "channel ~p, ~p", [EventType, Event]),
    ok.


handle_message(Message, #state{id = ChannelId, product = ProductId} = State) ->
    ?LOG(info, "Channel ~p, Product ~p, handle_message ~p", [ChannelId, ProductId, Message]),
    do_product(handle_info, [Message], State).

stop(ChannelType, ChannelId, _) ->
    ?LOG(info, "channel stop ~p,~p", [ChannelType, ChannelId]),
    ok.

%% =============
%% eSockd Callbacks
start_link(Transport, {Ip, Port}, State) ->
    {ok, proc_lib:spawn_link(?MODULE, do_init, [State#state{
        transport = Transport, ip = Ip, port = Port,
        log = log_fun(State#state.id)
    }])}.

do_init(#state{id = ChannelId} = State) ->
    case do_product(init, [ChannelId], State) of
        {ok, NewState} ->
            gen_server:enter_loop(?MODULE, [], NewState);
        {stop, Reason, NewState1} ->
            {stop, Reason, NewState1}
    end.

handle_info({datagram, _Server, Data0}, #state{env = OldEnv, log = Log} = State) ->
    Data = iolist_to_binary(Data0),
    Log(<<"RECV">>, Data),
    Env = OldEnv#{
        <<"send">> => send_fun(State)
    },
    case do_product(handle_info, [{udp, Data}], State#state{env = Env}) of
        {ok, NewState} ->
            {noreply, NewState};
        {stop, Reason, NewState} ->
            {stop, Reason, NewState}
    end;

handle_info(Info, State) ->
    case do_product(handle_info, [Info], State) of
        {ok, NewState} ->
            {noreply, NewState};
        {stop, Reason, NewState} ->
            {stop, Reason, NewState}
    end.

handle_call(_Msg, _From, State) ->
    {reply, ok, State}.

handle_cast(_Msg, State) ->
    {noreply, State}.

terminate(_Reason, _State) ->
    ok.

code_change(_OldVsn, State, _Extra) ->
    {ok, State}.


do_product(Fun, Args, #state{id = ChannelId, env = Env, product = ProductIds} = State) ->
    case dgiot_bridge:apply_channel(ChannelId, ProductIds, Fun, Args, Env) of
        {ok, NewEnv} ->
            {ok, update_state(NewEnv, State)};
        {stop, Reason, NewEnv} ->
            {stop, Reason, update_state(NewEnv, State)};
        {reply, ProductId, Reply, NewEnv} ->
            {reply, ProductId, Reply, update_state(NewEnv, State)}
    end.


update_state(Env, State) ->
    State#state{env = maps:without([<<"send">>], Env)}.


log_fun(ChannelId) ->
    fun(Type, Buff) ->
        Data =
            case Type of
                <<"ERROR">> -> Buff;
                _ -> <<<<Y>> || <<X:4>> <= Buff, Y <- integer_to_list(X, 16)>>
            end,
        dgiot_bridge:send_log(ChannelId, "~s", [<<Type/binary, " ", Data/binary>>])
    end.

send_fun(#state{ip = Ip, port = Port, transport = {udp, _Server, Sock}}) ->
    fun(Payload) ->
        % _Server ! {datagram, {Ip, Port}, Payload},
        gen_udp:send(Sock, Ip, Port, Payload)
    end.

