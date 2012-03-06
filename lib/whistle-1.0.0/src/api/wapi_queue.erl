%%%-------------------------------------------------------------------
%%% @copyright (C) 2012, VoIP INC
%%% @doc
%%%
%%% @end
%%% @contributors
%%%   James Aimonetti
%%%-------------------------------------------------------------------
-module(wapi_queue).

-export([agent_connected/1, agent_connected_v/1
         ,agent_disconnected/1, agent_disconnected_v/1
        ]).

-export([bind_q/2, unbind_q/2]).

-export([publish_agent_connected/1, publish_agent_connected/2
         ,publish_agent_disconnected/1, publish_agent_disconnected/2
        ]).

-include("../wh_api.hrl").

%%--------------------------------------------------------------------
%% @doc
%% Headers related to the API messages
%% @end
%%--------------------------------------------------------------------
-define(AGENT_CONNECTED_HEADERS, [<<"Account-ID">>, <<"Queue-ID">>, <<"Agent-ID">>]).
-define(OPTIONAL_AGENT_CONNECTED_HEADERS, []).
-define(AGENT_CONNECTED_VALUES, [{<<"Event-Category">>, <<"queue">>}
                                 ,{<<"Event-Name">>, <<"agent_connected">>}
                                ]).
-define(AGENT_CONNECTED_TYPES, []).

-define(AGENT_DISCONNECTED_HEADERS, [<<"Account-ID">>, <<"Queue-ID">>, <<"Agent-ID">>]).
-define(OPTIONAL_AGENT_DISCONNECTED_HEADERS, []).
-define(AGENT_DISCONNECTED_VALUES, [{<<"Event-Category">>, <<"queue">>}
                                 ,{<<"Event-Name">>, <<"agent_disconnected">>}
                          ]).
-define(AGENT_DISCONNECTED_TYPES, []).

%%--------------------------------------------------------------------
%% @doc Agent Connected - see wiki
%% Takes proplist, creates JSON iolist or error
%% @end
%%--------------------------------------------------------------------
-spec agent_connected/1 :: (api_terms()) -> {'ok', iolist()} | {'error', string()}.
agent_connected(Prop) when is_list(Prop) ->
            case agent_connected_v(Prop) of
            true -> wh_api:build_message(Prop, ?AGENT_CONNECTED_HEADERS, ?OPTIONAL_AGENT_CONNECTED_HEADERS);
            false -> {error, "Proplist failed validation for agent_connected"}
    end;
agent_connected(JObj) ->
    agent_connected(wh_json:to_proplist(JObj)).

-spec agent_connected_v/1 :: (api_terms()) -> boolean().
agent_connected_v(Prop) when is_list(Prop) ->
    wh_api:validate(Prop, ?AGENT_CONNECTED_HEADERS, ?AGENT_CONNECTED_VALUES, ?AGENT_CONNECTED_TYPES);
agent_connected_v(JObj) ->
    agent_connected_v(wh_json:to_proplist(JObj)).

%%--------------------------------------------------------------------
%% @doc Agent Disconnected - see wiki
%% Takes proplist, creates JSON iolist or error
%% @end
%%--------------------------------------------------------------------
-spec agent_disconnected/1 :: (api_terms()) -> {'ok', iolist()} | {'error', string()}.
agent_disconnected(Prop) when is_list(Prop) ->
            case agent_disconnected_v(Prop) of
            true -> wh_api:build_message(Prop, ?AGENT_DISCONNECTED_HEADERS, ?OPTIONAL_AGENT_DISCONNECTED_HEADERS);
            false -> {error, "Proplist failed validation for agent_disconnected"}
    end;
agent_disconnected(JObj) ->
    agent_disconnected(wh_json:to_proplist(JObj)).

-spec agent_disconnected_v/1 :: (api_terms()) -> boolean().
agent_disconnected_v(Prop) when is_list(Prop) ->
    wh_api:validate(Prop, ?AGENT_DISCONNECTED_HEADERS, ?AGENT_DISCONNECTED_VALUES, ?AGENT_DISCONNECTED_TYPES);
agent_disconnected_v(JObj) ->
    agent_disconnected_v(wh_json:to_proplist(JObj)).

%%--------------------------------------------------------------------
%% @doc bind_q
%% Bind a given queue to appropriate routing keys/exchanges
%% @end
%%--------------------------------------------------------------------
-spec bind_q/2 :: (ne_binary(), proplist()) -> 'ok'.
bind_q(Queue, Props) ->
    amqp_util:callmgr_exchange(),
    bind_q(Queue, props:get_value(restrict_to, Props), Props).

bind_q(Queue, undefined, Props) ->
    amqp_util:bind_q_to_callmgr(Queue, agent_binding_key(Props));
bind_q(Queue, [agents|T], Props) ->
    _ = amqp_util:bind_q_to_callmgr(Queue, agent_binding_key(Props)),
    bind_q(Queue, T, Props);
bind_q(Queue, [_|T], Props) ->
    bind_q(Queue, T, Props);
bind_q(_, [], _) ->
    ok.

%%--------------------------------------------------------------------
%% @doc unbind_q
%% Bind a given queue to appropriate routing keys/exchanges
%% @end
%%--------------------------------------------------------------------
-spec unbind_q/2 :: (ne_binary(), proplist()) -> 'ok'.
unbind_q(Queue, Props) ->
    unbind_q(Queue, props:get_value(restrict_to, Props), Props).

unbind_q(Queue, undefined, Props) ->
    amqp_util:unbind_q_from_callmgr(Queue, agent_binding_key(Props));
unbind_q(Queue, [agents|T], Props) ->
    _ = amqp_util:unbind_q_from_callmgr(Queue, agent_binding_key(Props)),
    unbind_q(Queue, T, Props);
unbind_q(Queue, [_|T], Props) ->
    unbind_q(Queue, T, Props);
unbind_q(_, [], _) ->
    ok.

%%--------------------------------------------------------------------
%% @doc 
%% Routing keys galore!
%% @end
%%--------------------------------------------------------------------
-spec agent_routing_key/1 :: (proplist()) -> ne_binary().
agent_routing_key(Props) ->
    list_to_binary([ <<"queue.agent.">>
                     ,props:get_value(account_id, Props, <<"*">>)
                     ,<<".">>
                     ,props:get_value(queue_id, Props, <<"*">>)
                   ]).

-spec agent_binding_key/1 :: (api_terms()) -> ne_binary().
agent_binding_key(Props) when is_list(Props) ->
    list_to_binary([ <<"queue.agent.">>
                     ,props:get_value(<<"Account-ID">>, Props)
                     ,<<".">>
                     ,props:get_value(<<"Queue-ID">>, Props)
                   ]);
agent_binding_key(JObj) ->
    agent_binding_key(wh_json:to_proplist(JObj)).

%%--------------------------------------------------------------------
%% @doc
%% Encode and publish the agent update message
%% @end
%%--------------------------------------------------------------------
-spec publish_agent_connected/1 :: (api_terms()) -> 'ok'.
-spec publish_agent_connected/2 :: (api_terms(), ne_binary()) -> 'ok'.
publish_agent_connected(Req) ->
    publish_agent_connected(Req, ?DEFAULT_CONTENT_TYPE).
publish_agent_connected(Req, ContentType) ->
    RoutingKey = list_to_binary([<<"transaction.agent_connected.">>, props:get_value(<<"Account-ID">>, Req)]),
    {ok, Payload} = wh_api:prepare_api_payload(Req, ?AGENT_CONNECTED_VALUES, fun ?MODULE:agent_connected/1),
    amqp_util:configuration_publish(RoutingKey, Payload, ContentType).

%%--------------------------------------------------------------------
%% @doc
%% Encode and publish the agent update message
%% @end
%%--------------------------------------------------------------------
-spec publish_agent_disconnected/1 :: (api_terms()) -> 'ok'.
-spec publish_agent_disconnected/2 :: (api_terms(), ne_binary()) -> 'ok'.
publish_agent_disconnected(Req) ->
    publish_agent_disconnected(Req, ?DEFAULT_CONTENT_TYPE).
publish_agent_disconnected(Req, ContentType) ->
    RoutingKey = list_to_binary([<<"transaction.agent_disconnected.">>, props:get_value(<<"Account-ID">>, Req)]),
    {ok, Payload} = wh_api:prepare_api_payload(Req, ?AGENT_DISCONNECTED_VALUES, fun ?MODULE:agent_disconnected/1),
    amqp_util:configuration_publish(RoutingKey, Payload, ContentType).
