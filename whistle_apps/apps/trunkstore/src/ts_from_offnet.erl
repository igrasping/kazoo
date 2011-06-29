%%%-------------------------------------------------------------------
%%% @author James Aimonetti <james@2600hz.org>
%%% @copyright (C) 2011, VoIP INC
%%% @doc
%%%
%%% @end
%%% Created : 20 Jun 2011 by James Aimonetti <james@2600hz.org>
%%%-------------------------------------------------------------------
-module(ts_from_offnet).

-export([start_link/1, init/2]).

-include("ts.hrl").

-record(state, {
	  aleg_callid = <<>> :: binary()
	  ,bleg_callid = <<>> :: binary()
          ,acctid = <<>> :: binary()
	  ,route_req_jobj = ?EMPTY_JSON_OBJECT :: json_object()
          ,endpoint = ?EMPTY_JSON_OBJECT :: json_object()
          ,my_q = <<>> :: binary()
          ,callctl_q = <<>> :: binary()
          ,failover = ?EMPTY_JSON_OBJECT :: json_object()
	 }).

-define(APP_NAME, <<"ts_from_offnet">>).
-define(APP_VERSION, <<"0.1.0">>).
-define(WAIT_FOR_WIN_TIMEOUT, 5000).
-define(WAIT_FOR_BRIDGE_TIMEOUT, 10000).
-define(WAIT_FOR_HANGUP_TIMEOUT, 1000 * 60 * 60 * 2). %% 2 hours
-define(WAIT_FOR_CDR_TIMEOUT, 5000).
-define(WAIT_FOR_OFFNET_BRIDGE, 60000). %% 1 minute

start_link(RouteReqJObj) ->
    proc_lib:start_link(?MODULE, init, [self(), RouteReqJObj]).

init(Parent, RouteReqJObj) ->
    proc_lib:init_ack(Parent, {ok, self()}),
    CallID = wh_json:get_value(<<"Call-ID">>, RouteReqJObj),
    put(callid, CallID),
    ?LOG("init done"),
    start_amqp(#state{aleg_callid=CallID, route_req_jobj=RouteReqJObj, acctid=wh_json:get_value([<<"Custom-Channel-Vars">>, <<"Account-ID">>], RouteReqJObj)}).

start_amqp(#state{route_req_jobj=JObj}=State) ->
    Q = amqp_util:new_queue(),

    %% Bind the queue to an exchange
    _ = amqp_util:bind_q_to_targeted(Q),
    amqp_util:basic_consume(Q, [{exclusive, false}]),

    ?LOG("AMQP started: ~s", [Q]),
    endpoint_data(State#state{my_q=Q}, JObj).

endpoint_data(#state{aleg_callid=CallID, acctid=AcctID}=State, JObj) ->
    try
        {endpoint, EP} = endpoint_data(JObj),
        ?LOG("Endpoint loaded"),
        send_park(State#state{endpoint=EP})
    catch
        _A:_B ->
            ?LOG("Exception when routing from offnet"),
            ?LOG("~p:~p", [_A, _B]),
            ?LOG("Stacktrace: ~p", [erlang:get_stacktrace()]),
            ?LOG("release ~s for ~s", [CallID, AcctID]),
            ts_acctmgr:release_trunk(AcctID, CallID, 0)
    end.

send_park(#state{route_req_jobj=JObj, my_q=Q, aleg_callid=CallID, acctid=AcctID}=State) ->
    JObj1 = {struct, [ {<<"Msg-ID">>, wh_json:get_value(<<"Msg-ID">>, JObj)}
                       ,{<<"Routes">>, []}
                       ,{<<"Method">>, <<"park">>}
		       | whistle_api:default_headers(Q, <<"dialplan">>, <<"route_resp">>, ?APP_NAME, ?APP_VERSION) ]
	    },
    RespQ = wh_json:get_value(<<"Server-ID">>, JObj),
    try
        {ok, JSON} = whistle_api:route_resp(JObj1),
        ?LOG("Sending to ~s: ~s", [RespQ, JSON]),
        amqp_util:targeted_publish(RespQ, JSON, <<"application/json">>),

        wait_for_win(State, ?WAIT_FOR_WIN_TIMEOUT)
    catch
        _A:_B ->
            ?LOG("Failed to create and send route_resp"),
            ?LOG("Exception ~p: ~p", [_A, _B]),
            ?LOG("Release ~s from ~s", [CallID, AcctID]),
            ts_acctmgr:release_trunk(AcctID, CallID, 0)
    end.

wait_for_win(#state{aleg_callid=CallID, my_q=Q, acctid=AcctID}=State, Timeout) ->
    receive
        #'basic.consume_ok'{} -> wait_for_win(State, Timeout);

	{_, #amqp_msg{payload=Payload}} ->
            try
                WinJObj = mochijson2:decode(Payload),
                true = whistle_api:route_win_v(WinJObj),

                ?LOG("Route win received"),
                CallID = wh_json:get_value(<<"Call-ID">>, WinJObj),

                _ = amqp_util:bind_q_to_callevt(Q, CallID),
                _ = amqp_util:bind_q_to_callevt(Q, CallID, cdr),
                amqp_util:basic_consume(Q, [{exclusive, false}]), %% not sure yet if need to re-call consume/2 here

                CallctlQ = wh_json:get_value(<<"Control-Queue">>, WinJObj),

                bridge_to_endpoint(State#state{callctl_q=CallctlQ})
            catch
                _A:_B ->
                    ?LOG("Failed to validate route_win_v"),
                    ?LOG("Exception ~p: ~p", [_A, _B]),
                    ?LOG("Release ~s from ~s", [CallID, AcctID]),
                    ts_acctmgr:release_trunk(AcctID, CallID, 0)
            end
    after Timeout ->
	    ?LOG("Timed out(~b) waiting for route_win", [Timeout]),
	    _ = amqp_util:bind_q_to_callevt(Q, CallID),
	    _ = amqp_util:bind_q_to_callevt(Q, CallID, cdr),
	    wait_for_bridge(State, ?WAIT_FOR_BRIDGE_TIMEOUT)
    end.

bridge_to_endpoint(#state{callctl_q=CtlQ, my_q=Q, aleg_callid=CallID, acctid=AcctID, endpoint=EP}=State) ->
    try
        true = whistle_api:bridge_req_endpoint_v(EP),
        ?LOG("Valid endpoint"),
        Command = [
                   {<<"Application-Name">>, <<"bridge">>}
                   ,{<<"Endpoints">>, [EP]}
                   ,{<<"Timeout">>, <<"26">>}
                   ,{<<"Dial-Endpoint-Method">>, <<"single">>}
                   ,{<<"Call-ID">>, CallID}
                   | whistle_api:default_headers(Q, <<"call">>, <<"command">>, ?APP_NAME, ?APP_VERSION)
                  ],
        {ok, Payload} = whistle_api:bridge_req([ KV || {_, V}=KV <- Command, V =/= undefined, V =/= <<>> ]),
        ?LOG(CallID, "Sending bridge command: ~s", [Payload]),
        amqp_util:callctl_publish(CtlQ, Payload),
        wait_for_bridge(State#state{failover=wh_json:get_value(<<"Failover">>, EP, ?EMPTY_JSON_OBJECT)}, ?WAIT_FOR_BRIDGE_TIMEOUT)
    catch
        _A:_B ->
            ?LOG("Failed to send bridge_req"),
            ?LOG("Exception ~p:~p", [_A, _B]),
            ?LOG("Release ~s from ~s", [CallID, AcctID]),
            ts_acctmgr:release_trunk(AcctID, CallID, 0)
    end.

wait_for_bridge(State, Timeout) ->
    Start = erlang:now(),
    receive
	{_, #amqp_msg{payload=Payload}} ->
            JObj = mochijson2:decode(Payload),

            case whistle_api:call_event_v(JObj) of
                true ->
                    ?LOG("Event received, processing"),
                    process_event(State, Timeout - (timer:now_diff(erlang:now(), Start) div 1000), JObj);
                false ->
                    ?LOG("Ignoring possible event payload: ~s", [Payload]),
                    wait_for_bridge(State, Timeout - (timer:now_diff(erlang:now(), Start) div 1000))
            end
    after Timeout ->
	    ?LOG("Timed out(~b) waiting for bridge success", [Timeout])
    end.

process_event(#state{aleg_callid=ALeg, acctid=AcctID, my_q=Q}=State, Timeout, JObj) ->
    Start = erlang:now(),
    try
        case { wh_json:get_value(<<"Application-Name">>, JObj)
               ,wh_json:get_value(<<"Event-Name">>, JObj)
               ,wh_json:get_value(<<"Event-Category">>, JObj) } of
            { _, <<"CHANNEL_BRIDGE">>, <<"call_event">> } ->
                BLeg = wh_json:get_value(<<"Other-Leg-Call-Id">>, JObj),
                _ = amqp_util:bind_q_to_callevt(Q, BLeg, cdr),
                ?LOG("Bridge to ~s successful", [BLeg]),
                wait_for_cdr(State#state{bleg_callid=BLeg});
            { <<"bridge">>, <<"CHANNEL_EXECUTE_COMPLETE">>, <<"call_event">> } ->
                ?LOG("Bridge event received"),
                case wh_json:get_value(<<"Application-Response">>, JObj) of
                    <<"SUCCESS">> ->
                        BLeg = wh_json:get_value(<<"Other-Leg-Call-Id">>, JObj),
                        _ = amqp_util:bind_q_to_callevt(Q, BLeg, cdr),
                        ?LOG("Bridge to ~s successful", [BLeg]),
                        wait_for_cdr(State#state{bleg_callid=BLeg});
                    Cause ->
                        ?LOG("Failed to bridge: ~s", [Cause]),
                        try_failover(State)
                end;
            { _, <<"CHANNEL_HANGUP">>, <<"call_event">> } ->
                ?LOG("Release ~s from ~s", [ALeg, AcctID]),
                ok = ts_acctmgr:release_trunk(AcctID, ALeg, 0),
                ?LOG("Channel hungup");
            { _, _, <<"error">> } ->
                ?LOG("Release ~s from ~s", [ALeg, AcctID]),
                ok = ts_acctmgr:release_trunk(AcctID, ALeg, 0),
                ?LOG("Execution failed");
            _Other ->
                ?LOG("Received other: ~p~n", [_Other]),
                Diff = Timeout - (timer:now_diff(erlang:now(), Start) div 1000),
                ?LOG("~b left to timeout", [Diff]),
                wait_for_bridge(State, Diff)
        end
    catch
        _A:_B ->
            ?LOG("Failed to validate call event"),
            ?LOG("Exception ~p: ~p", [_A, _B]),
            ?LOG("Release ~s from ~s", [ALeg, AcctID]),
            ts_acctmgr:release_trunk(AcctID, ALeg, 0)
    end.


wait_for_cdr(State) ->
    wait_for_cdr(State, ?WAIT_FOR_HANGUP_TIMEOUT).
wait_for_cdr(#state{aleg_callid=ALeg, acctid=AcctID}=State, Timeout) ->
    receive
	{_, #amqp_msg{payload=Payload}} ->
	    JObj = mochijson2:decode(Payload),
            case { wh_json:get_value(<<"Event-Category">>, JObj)
		   ,wh_json:get_value(<<"Event-Name">>, JObj) } of
                { <<"call_event">>, <<"CHANNEL_HANGUP">> } ->
		    ?LOG("Hangup received, waiting on CDR"),
		    wait_for_cdr(State, ?WAIT_FOR_CDR_TIMEOUT);
                { <<"error">>, _ } ->
		    ?LOG("Received error in event stream, waiting for CDR"),
		    wait_for_cdr(State, ?WAIT_FOR_CDR_TIMEOUT);
		{ <<"cdr">>, <<"call_detail">> } ->
		    true = whistle_api:call_cdr_v(JObj),
		    Leg = wh_json:get_value(<<"Call-ID">>, JObj),
		    Duration = ts_util:get_call_duration(JObj),

		    {R, RI, RM, S} = ts_util:get_rate_factors(JObj),
		    Cost = ts_util:calculate_cost(R, RI, RM, S, Duration),

		    ?LOG("CDR received for leg ~s", [Leg]),
		    ?LOG("Leg to be billed for ~b seconds", [Duration]),
		    ?LOG("Acct ~s to be charged ~p if per_min", [AcctID, Cost]),

                    ?LOG("Release ~s from ~s", [Leg, AcctID]),
		    ok = ts_acctmgr:release_trunk(AcctID, Leg, Cost),

		    _ = ts_cdr:store(JObj),

		    wait_for_cdr(State, ?WAIT_FOR_CDR_TIMEOUT);
                _ ->
                    wait_for_cdr(State, ?WAIT_FOR_HANGUP_TIMEOUT)
            end
    after Timeout ->
	    ?LOG("Timed out(~b) waiting for CDR"),
	    %% will fail if already released
	    ts_acctmgr:release_trunk(AcctID, ALeg, 0)
    end.

try_failover(#state{failover=?EMPTY_JSON_OBJECT, aleg_callid=CallID, acctid=AcctID}) ->
    ?LOG_END("No failover configured, ending"),
    ?LOG("Release ~s from ~s", [CallID, AcctID]),
    ok = ts_acctmgr:release_trunk(AcctID, CallID, 0);
try_failover(#state{failover=FailJObj}=State) ->
    case wh_json:get_value(<<"e164">>, FailJObj) of
	undefined -> try_failover_sip(State, wh_json:get_value(<<"sip">>, FailJObj));
	DID -> try_failover_e164(State, DID)
    end.

try_failover_sip(#state{acctid=AcctID, aleg_callid=CallID, callctl_q = <<>>}, _) ->
    ?LOG("No control queue to try SIP failover"),
    ?LOG("Release ~s from ~s", [CallID, AcctID]),
    ok = ts_acctmgr:release_trunk(AcctID, CallID, 0);
try_failover_sip(#state{aleg_callid=CallID, callctl_q=CtlQ}=State, SIPUri) ->
    EndPoint = {struct, [
			 {<<"Invite-Format">>, <<"route">>}
			 ,{<<"Route">>, SIPUri}
			]},

    %% since we only route to one endpoint, we specify most options on the endpoint's leg
    Command = [
	       {<<"Call-ID">>, CallID}
	       ,{<<"Application-Name">>, <<"bridge">>}
	       ,{<<"Endpoints">>, [EndPoint]}
	      ],

    {ok, Payload} = whistle_api:bridge_req([ KV || {_, V}=KV <- Command, V =/= undefined, V =/= <<>> ]),

    ?LOG("Sending SIP failover for ~s: ~s", [SIPUri, Payload]),

    amqp_util:targeted_publish(CtlQ, Payload),
    wait_for_bridge(State#state{failover=?EMPTY_JSON_OBJECT}, ?WAIT_FOR_BRIDGE_TIMEOUT).

try_failover_e164(#state{acctid=AcctID, aleg_callid=CallID, callctl_q = <<>>}, _) ->
    ?LOG("No control queue to try E.164 failover"),
    ?LOG("Release ~s from ~s", [CallID, AcctID]),
    ts_acctmgr:release_trunk(AcctID, CallID, 0);
try_failover_e164(#state{acctid=AcctID, aleg_callid=CallID, callctl_q=CallctlQ, my_q=Q, endpoint=EP}=State, ToDID) ->
    FailCallID = <<CallID/binary, "-failover">>,
    {ok, RateData} = ts_credit:reserve(ToDID, FailCallID, AcctID, outbound, wh_json:get_value(<<"Route-Options">>, EP)),
    Command = [
	       {<<"Call-ID">>, CallID}
	       ,{<<"Resource-Type">>, <<"audio">>}
	       ,{<<"To-DID">>, ToDID}
	       ,{<<"Account-ID">>, AcctID}
	       ,{<<"Control-Queue">>, CallctlQ}
	       ,{<<"Application-Name">>, <<"bridge">>}
	       ,{<<"Custom-Channel-Vars">>, {struct, RateData}}
	       ,{<<"Flags">>, wh_json:get_value(<<"flags">>, EP)}
	       ,{<<"Timeout">>, wh_json:get_value(<<"timeout">>, EP)}
	       ,{<<"Ignore-Early-Media">>, wh_json:get_value(<<"ignore_early_media">>, EP)}
	       ,{<<"Outgoing-Caller-ID-Name">>, wh_json:get_value(<<"Outgoing-Caller-ID-Name">>, EP)}
	       ,{<<"Outgoing-Caller-ID-Number">>, wh_json:get_value(<<"Outgoing-Caller-ID-Number">>, EP)}
	       ,{<<"Ringback">>, wh_json:get_value(<<"ringback">>, EP)}
	       | whistle_api:default_headers(Q, <<"resource">>, <<"offnet_req">>, ?APP_NAME, ?APP_VERSION)
	      ],
    {ok, Payload} = whistle_api:offnet_resource_req([ KV || {_, V}=KV <- Command, V =/= undefined, V =/= <<>> ]),
    amqp_util:offnet_resource_publish(Payload),
    wait_for_offnet_bridge(State#state{aleg_callid=FailCallID}, ?WAIT_FOR_OFFNET_BRIDGE).

wait_for_offnet_bridge(#state{aleg_callid=CallID, callctl_q=CtlQ, acctid=AcctID, my_q=Q}=State, Timeout) ->
    Start = erlang:now(),
    receive
	{_, #amqp_msg{payload=Payload}} ->
	    JObj = mochijson2:decode(Payload),
	    case { wh_json:get_value(<<"Event-Name">>, JObj), wh_json:get_value(<<"Event-Category">>, JObj) } of
                { <<"offnet_resp">>, <<"resource">> } ->
		    BLegCallID = wh_json:get_value(<<"Call-ID">>, JObj),
		    _ = amqp_util:bind_q_to_callevt(Q, BLegCallID, cdr),
		    ?LOG("Bridging offnet to callid ~s", [BLegCallID]),
		    ?LOG(BLegCallID, "Bridged to a-leg ~s", [CallID]),
		    wait_for_offnet_cdr(State#state{bleg_callid=BLegCallID}, ?WAIT_FOR_HANGUP_TIMEOUT);
                { <<"resource_error">>, <<"resource">> } ->
		    Code = wh_json:get_value(<<"Failure-Code">>, JObj, <<"486">>),
		    Message = wh_json:get_value(<<"Failure-Message">>, JObj),

		    ?LOG("Failed to bridge offnet"),
		    ?LOG("Failure message: ~s", [Message]),
		    ?LOG("Failure code: ~s", [Code]),

		    %% send failure code to Call
		    whistle_util:call_response(CallID, CtlQ, Code, Message),

                    ?LOG("release ~s for ~s", [CallID, AcctID]),
		    ts_acctmgr:release_trunk(AcctID, CallID, 0);
                { <<"CHANNEL_HANGUP">>, <<"call_event">> } ->
		    ?LOG("Hangup received"),
                    ?LOG("Release ~s from ~s", [CallID, AcctID]),
		    ts_acctmgr:release_trunk(AcctID, CallID, 0);
                { _, <<"error">> } ->
		    ?LOG("Error received"),
                    ?LOG("Release ~s from ~s", [CallID, AcctID]),
		    ts_acctmgr:release_trunk(AcctID, CallID, 0);
                _ ->
		    Diff = Timeout - (timer:now_diff(erlang:now(), Start) div 1000),
                    wait_for_offnet_bridge(State, Diff)
            end;
        _ ->
            Diff = Timeout - (timer:now_diff(erlang:now(), Start) div 1000),
            wait_for_offnet_bridge(State, Diff)
    after Timeout ->
	    ?LOG("Offnet bridge timed out(~b)", [Timeout]),
	    ts_acctmgr:release_trunk(AcctID, CallID, 0)
    end.

wait_for_offnet_cdr(#state{aleg_callid=ALeg, bleg_callid=BLeg, acctid=AcctID}=State, Timeout) ->
    receive
	{_, #amqp_msg{payload=Payload}} ->
	    JObj = mochijson2:decode(Payload),
            case { wh_json:get_value(<<"Event-Category">>, JObj)
		   ,wh_json:get_value(<<"Event-Name">>, JObj) } of
                { <<"call_event">>, <<"CHANNEL_HANGUP">> } ->
		    ?LOG("Hangup received, waiting on CDR"),
		    wait_for_cdr(State, ?WAIT_FOR_CDR_TIMEOUT);
                { <<"error">>, _ } ->
		    ?LOG("Received error in event stream, waiting for CDR"),
		    wait_for_cdr(State, ?WAIT_FOR_CDR_TIMEOUT);
		{ <<"cdr">>, <<"call_detail">> } ->
		    true = whistle_api:call_cdr_v(JObj),

		    Leg = wh_json:get_value(<<"Call-ID">>, JObj),
		    Duration = ts_util:get_call_duration(JObj),

		    {R, RI, RM, S} = ts_util:get_rate_factors(JObj),
		    Cost = ts_util:calculate_cost(R, RI, RM, S, Duration),

		    ?LOG("CDR received for leg ~s", [Leg]),
		    ?LOG("Leg to be billed for ~b seconds", [Duration]),
		    ?LOG("Acct ~s to be charged ~p if per_min", [AcctID, Cost]),

		    case Leg =:= BLeg of
			true -> ?LOG("Release ~s from ~s", [Leg, AcctID]), ts_acctmgr:release_trunk(AcctID, Leg, Cost);
			false -> ?LOG("Release ~s from ~s", [ALeg, AcctID]), ts_acctmgr:release_trunk(AcctID, ALeg, Cost)
		    end,

		    wait_for_cdr(State, ?WAIT_FOR_CDR_TIMEOUT);
                _ ->
                    wait_for_cdr(State, ?WAIT_FOR_HANGUP_TIMEOUT)
            end
    after Timeout ->
	    ?LOG("Timed out(~b) waiting for CDR"),
	    %% will fail if already released
            ?LOG("Release ~s from ~s", [ALeg, AcctID]),
	    ts_acctmgr:release_trunk(AcctID, ALeg, 0)
    end.

%%--------------------------------------------------------------------
%% Out-of-band functions
%%--------------------------------------------------------------------
-spec(endpoint_data/1 :: (JObj :: json_object()) -> tuple(endpoint, json_object()) | tuple(error, atom())).
endpoint_data(JObj) ->
    %% wh_timer:tick("inbound_route/1"),
    AcctID = wh_json:get_value([<<"Custom-Channel-Vars">>, <<"Account-ID">>], JObj),
    CallID = wh_json:get_value(<<"Call-ID">>, JObj),

    ?LOG("EP: AcctID: ~s", [AcctID]),

    ToDID = case binary:split(wh_json:get_value(<<"To">>, JObj), <<"@">>) of
                [<<"nouser">>, _] ->
                    [ReqU, _] = binary:split(wh_json:get_value(<<"Request">>, JObj), <<"@">>),
                    ?LOG("EP: ReqU: ~s", [ReqU]),
                    whistle_util:to_e164(ReqU);
                [T, _] ->
                    ?LOG("EP: ToUser: ~s", [T]),
                    whistle_util:to_e164(T)
            end,
    ?LOG("EP: ToDID: ~s", [ToDID]),

    RoutingData = routing_data(ToDID),

    AuthUser = props:get_value(<<"To-User">>, RoutingData),
    AuthRealm = props:get_value(<<"To-Realm">>, RoutingData),

    ?LOG("EP: AuthUser: ~s", [AuthUser]),
    ?LOG("EP: AuthRealm: ~s", [AuthRealm]),

    case ts_credit:reserve(ToDID, CallID, AcctID, inbound, props:get_value(<<"Route-Options">>, RoutingData)) of
        {error, _}=E -> ?LOG("Release ~s from ~s", [CallID, AcctID]), ok = ts_acctmgr:release_trunk(AcctID, CallID, 0), E;
        {ok, RateData} ->
            InFormat = props:get_value(<<"Invite-Format">>, RoutingData, <<"username">>),
            Invite = ts_util:invite_format(whistle_util:binary_to_lower(InFormat), ToDID) ++ RoutingData,

            {endpoint, {struct, [{<<"Custom-Channel-Vars">>, {struct, [
                                                                       {<<"Auth-User">>, AuthUser}
                                                                       ,{<<"Auth-Realm">>, AuthRealm}
                                                                       ,{<<"Direction">>, <<"inbound">>}
                                                                       | RateData
                                                                      ]}
                                 }
                                 | Invite ]
                       }}
    end.

-spec(routing_data/1 :: (ToDID :: binary()) -> proplist()).
routing_data(ToDID) ->
    {ok, Settings} = ts_util:lookup_did(ToDID),

    ?LOG("Got DID settings"),

    AuthOpts = wh_json:get_value(<<"auth">>, Settings, ?EMPTY_JSON_OBJECT),
    Acct = wh_json:get_value(<<"account">>, Settings, ?EMPTY_JSON_OBJECT),
    DIDOptions = wh_json:get_value(<<"DID_Opts">>, Settings, ?EMPTY_JSON_OBJECT),
    RouteOpts = wh_json:get_value(<<"options">>, DIDOptions, []),

    AuthU = wh_json:get_value(<<"auth_user">>, AuthOpts),
    AuthR = wh_json:get_value(<<"auth_realm">>, AuthOpts, wh_json:get_value(<<"auth_realm">>, Acct)),

    {Srv, AcctStuff} = try
                      {ok, AccountSettings} = ts_util:lookup_user_flags(AuthU, AuthR),
                      ?LOG("Got account settings"),
                      {
                        wh_json:get_value(<<"server">>, AccountSettings, ?EMPTY_JSON_OBJECT)
                        ,wh_json:get_value(<<"account">>, AccountSettings, ?EMPTY_JSON_OBJECT)
                      }
                  catch
                      _A:_B ->
                          ?LOG("Failed to get account settings: ~p: ~p", [_A, _B]),
                          {?EMPTY_JSON_OBJECT, ?EMPTY_JSON_OBJECT}
                  end,

    SrvOptions = wh_json:get_value(<<"options">>, Srv, ?EMPTY_JSON_OBJECT),

    true = whistle_util:is_true(wh_json:get_value(<<"enabled">>, SrvOptions)),

    InboundFormat = wh_json:get_value(<<"inbound_format">>, SrvOptions, <<"npan">>),

    {CalleeName, CalleeNumber} = callee_id([
					    wh_json:get_value(<<"caller_id">>, DIDOptions)
                                            ,wh_json:get_value(<<"callerid_account">>, Settings)
                                            ,wh_json:get_value(<<"callerid_server">>, Settings)
                                           ]),

    ProgressTimeout = progress_timeout([
					wh_json:get_value(<<"progress_timeout">>, DIDOptions)
					,wh_json:get_value(<<"progress_timeout">>, SrvOptions)
					,wh_json:get_value(<<"progress_timeout">>, AcctStuff)
				       ]),

    BypassMedia = bypass_media([
				wh_json:get_value(<<"media_handling">>, DIDOptions)
				,wh_json:get_value(<<"media_handling">>, SrvOptions)
				,wh_json:get_value(<<"media_handling">>, AcctStuff)
			       ]),

    Failover = failover([
			 wh_json:get_value(<<"failover">>, DIDOptions)
			 ,wh_json:get_value(<<"failover">>, SrvOptions)
			 ,wh_json:get_value(<<"failover">>, AcctStuff)
			]),

    Delay = delay([
		   wh_json:get_value(<<"delay">>, DIDOptions)
		   ,wh_json:get_value(<<"delay">>, SrvOptions)
		   ,wh_json:get_value(<<"delay">>, AcctStuff)
		  ]),

    SIPHeaders = sip_headers([
			      wh_json:get_value(<<"sip_headers">>, DIDOptions)
			      ,wh_json:get_value(<<"sip_headers">>, SrvOptions)
			      ,wh_json:get_value(<<"sip_headers">>, AcctStuff)
			      ]),

    IgnoreEarlyMedia = ignore_early_media([
					   wh_json:get_value(<<"ignore_early_media">>, DIDOptions)
					   ,wh_json:get_value(<<"ignore_early_media">>, SrvOptions)
					   ,wh_json:get_value(<<"ignore_early_media">>, AcctStuff)
					  ]),

    Timeout = ep_timeout([
			  wh_json:get_value(<<"timeout">>, DIDOptions)
			  ,wh_json:get_value(<<"timeout">>, SrvOptions)
			  ,wh_json:get_value(<<"timeout">>, AcctStuff)
			 ]),

    %% Bridge Endpoint fields go here
    %% See http://wiki.2600hz.org/display/whistle/Dialplan+Actions#DialplanActions-Endpoint
    [KV || {_,V}=KV <- [ {<<"Invite-Format">>, InboundFormat}
			 ,{<<"Codecs">>, wh_json:get_value(<<"codecs">>, Srv)}
			 ,{<<"Bypass-Media">>, BypassMedia}
			 ,{<<"Endpoint-Progress-Timeout">>, ProgressTimeout}
			 ,{<<"Failover">>, Failover}
			 ,{<<"Endpoint-Delay">>, Delay}
			 ,{<<"SIP-Headers">>, SIPHeaders}
			 ,{<<"Ignore-Early-Media">>, IgnoreEarlyMedia}
			 ,{<<"Endpoint-Timeout">>, Timeout}
			 ,{<<"Callee-ID-Name">>, CalleeName}
			 ,{<<"Callee-ID-Number">>, CalleeNumber}
			 ,{<<"To-User">>, AuthU}
			 ,{<<"To-Realm">>, AuthR}
			 ,{<<"To-DID">>, ToDID}
			 ,{<<"Route-Options">>, RouteOpts}
			 %% ,{<<"Outgoing-Caller-ID-Name">>, wh_json:get_value(<<"Outgoing-Caller-ID-Name">>, EP)}
			 %% ,{<<"Outgoing-Caller-ID-Number">>, wh_json:get_value(<<"Outgoing-Caller-ID-Number">>, EP)}
		       ],
	   V =/= undefined,
	   V =/= <<>> ].

callee_id([]) -> {undefined, undefined};
callee_id([undefined | T]) -> callee_id(T);
callee_id([?EMPTY_JSON_OBJECT | T]) -> callee_id(T);
callee_id([<<>> | T]) -> callee_id(T);
callee_id([{struct, [_|_]}=JObj | T]) ->
    case {wh_json:get_value(<<"cid_name">>, JObj), wh_json:get_value(<<"cid_number">>, JObj)} of
        {undefined, undefined} ->
            callee_id(T);
        CalleeID -> CalleeID
    end.

sip_headers(L) ->
    sip_headers(L, []).
sip_headers([undefined | T], Acc) ->
    sip_headers(T, Acc);
sip_headers([?EMPTY_JSON_OBJECT | T], Acc) ->
    sip_headers(T, Acc);
sip_headers([{struct, [_|_]=H}|T], Acc) ->
    sip_headers(T, H ++ Acc);
sip_headers([_|T], Acc) ->
    sip_headers(T, Acc);
sip_headers([], []) ->
    undefined;
sip_headers([], Acc) ->
    {struct, lists:reverse(Acc)}.

%% cascade from DID to Srv to Acct
failover(L) -> simple_extract(L).
progress_timeout(L) -> simple_extract(L).
bypass_media(L) -> simple_extract(L).
delay(L) -> simple_extract(L).
ignore_early_media(L) -> simple_extract(L).
ep_timeout(L) -> simple_extract(L).

-spec simple_extract/1 :: (L) -> undefined | json_object() | binary() when
      L :: list(undefined | json_object() | binary()).
simple_extract([undefined|T]) ->
    simple_extract(T);
simple_extract([?EMPTY_JSON_OBJECT | T]) ->
    simple_extract(T);
simple_extract([{struct, _}=F | _]) ->
    F;
simple_extract([B | _]) when is_binary(B) andalso B =/= <<>> ->
    B;
simple_extract([_ | T]) ->
    simple_extract(T);
simple_extract([]) ->
    undefined.
