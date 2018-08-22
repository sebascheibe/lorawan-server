%
% Copyright (c) 2016-2018 Petr Gotthard <petr.gotthard@centrum.cz>
% All rights reserved.
% Distributed under the terms of the MIT License. See the LICENSE file.
%
-module(lorawan_application_backend).
-behaviour(lorawan_application).

-export([init/1, handle_join/3, handle_uplink/4, handle_rxq/5, handle_delivery/3]).
-export([handle_downlink/2]).

-include("lorawan.hrl").
-include("lorawan_db.hrl").

init(_App) ->
    ok.

handle_join({_Network, #profile{app=AppID}, Device}, {_MAC, _RxQ}, DevAddr) ->
    case mnesia:dirty_read(handlers, AppID) of
        [Handler] ->
            send_event(joined, #{}, Handler, {Device, DevAddr});
        [] ->
            {error, {unknown_application, AppID}}
    end.

handle_uplink({Network, #profile{app=AppID}, #node{devaddr=DevAddr}=Node}, _RxQ, LastMissed, Frame) ->
    case mnesia:dirty_read(handlers, AppID) of
        [#handler{downlink_expires=Expires}=Handler] ->
            case LastMissed of
                {missed, _Receipt} ->
                    case lorawan_application:get_stored_frames(DevAddr) of
                        [] ->
                            retransmit;
                        List when length(List) > 0, Expires == <<"never">> ->
                            retransmit;
                        _Else ->
                            handle_uplink0(Handler, Network, Node, Frame)
                    end;
                undefined ->
                    handle_uplink0(Handler, Network, Node, Frame)
            end;
        [] ->
            {error, {unknown_application, AppID}}
    end.

handle_uplink0(#handler{app=AppID, uplink_fields=Fields}=Handler, Network, Node, Frame) ->
    Vars = parse_uplink(Handler, Network, Node, Frame),
    case any_is_member([<<"freq">>, <<"datr">>, <<"codr">>, <<"best_gw">>,
            <<"mac">>, <<"lsnr">>, <<"rssi">>, <<"all_gw">>], Fields) of
        true ->
            % we have to wait for the rx quality indicators
            {ok, {Handler, Vars}};
        false ->
            lorawan_backend_factory:uplink(AppID, Node, Vars),
            {ok, undefined}
    end.

handle_rxq({_Network, _Profile, #node{devaddr=DevAddr}},
        _Gateways, _WillReply, #frame{port=Port}, undefined) ->
    % we did already handle this uplink
    lorawan_application:send_stored_frames(DevAddr, Port);
handle_rxq({_Network, #profile{app=AppID}, #node{devaddr=DevAddr}=Node},
        Gateways, _WillReply, #frame{port=Port}, {#handler{uplink_fields=Fields}, Vars}) ->
    lorawan_backend_factory:uplink(AppID, Node, parse_rxq(Gateways, Fields, Vars)),
    lorawan_application:send_stored_frames(DevAddr, Port).

any_is_member(_List1, undefined) ->
    false;
any_is_member(List1, List2) ->
    lists:any(
        fun(Item1) ->
            lists:member(Item1, List2)
        end,
        List1).

parse_uplink(#handler{app=AppID, payload=Payload, parse_uplink=Parse, uplink_fields=Fields},
        #network{netid=NetID},
        #node{appargs=AppArgs, devstat=DevStat},
        #frame{devaddr=DevAddr, fcnt=FCnt, port=Port, data=Data}) ->
    Vars =
        vars_add(netid, NetID, Fields,
        vars_add(app, AppID, Fields,
        vars_add(devaddr, DevAddr, Fields,
        vars_add(deveui, get_deveui(DevAddr), Fields,
        vars_add(appargs, AppArgs, Fields,
        vars_add(battery, get_battery(DevStat), Fields,
        vars_add(fcnt, FCnt, Fields,
        vars_add(port, Port, Fields,
        vars_add(data, Data, Fields,
        vars_add(datetime, calendar:universal_time(), Fields,
        parse_payload(Payload, Data))))))))))),
    data_to_fields(AppID, Parse, Vars, Data).

parse_rxq(Gateways, Fields, Vars) ->
    {MAC1, #rxq{freq=Freq, datr=Datr, codr=Codr, rssi=RSSI1, lsnr=SNR1}} = hd(Gateways),
    RxQ =
        lists:map(
            fun({MAC, #rxq{time=Time, rssi=RSSI, lsnr=SNR}}) ->
                #{mac=>MAC, rssi=>RSSI, lsnr=>SNR, time=>Time}
            end,
            Gateways),
    vars_add(freq, Freq, Fields,
        vars_add(datr, Datr, Fields,
        vars_add(codr, Codr, Fields,
        vars_add(best_gw, hd(RxQ), Fields,
        vars_add(mac, MAC1, Fields,
        vars_add(lsnr, SNR1, Fields,
        vars_add(rssi, RSSI1, Fields,
        vars_add(all_gw, RxQ, Fields,
        Vars)))))))).

vars_add(_Field, Value, Fields, Vars)
        when Value == undefined; Fields == undefined ->
    Vars;
vars_add(Field, Value, Fields, Vars) ->
    case lists:member(atom_to_binary(Field, latin1), Fields) of
        true ->
            Vars#{Field => Value};
        false ->
            Vars
    end.

get_deveui(DevAddr) ->
    case mnesia:dirty_index_read(devices, DevAddr, #device.node) of
        [#device{deveui=DevEUI}|_] -> DevEUI;
        [] -> undefined
    end.

get_battery([{_DateTime, Battery, _Margin, _MaxSNR}|_]) ->
    Battery;
get_battery(_Else) ->
    undefined.

data_to_fields(AppId, {_, Fun}, Vars, Data) when is_function(Fun) ->
    try Fun(Vars, Data)
    catch
        Error:Term ->
            lorawan_utils:throw_error({handler, AppId}, {parse_failed, {Error, Term}}),
            Vars
    end;
data_to_fields(_AppId, _Else, Vars, _) ->
    Vars.

handle_delivery({_Network, #profile{app=AppID}, Node}, Result, Receipt) ->
    case mnesia:dirty_read(handlers, AppID) of
        [Handler] ->
            send_event(Result, #{receipt => Receipt}, Handler, Node);
        [] ->
            {error, {unknown_application, AppID}}
    end.

send_event(Event, Vars0, #handler{app=AppID, event_fields=Fields, parse_event=Parse}, DeviceOrNode) ->
    Vars =
        vars_add(app, AppID, Fields,
        vars_add(event, Event, Fields,
        vars_add(datetime, calendar:universal_time(), Fields,
        case DeviceOrNode of
            {#device{deveui=DevEUI, appargs=AppArgs}, DevAddr} ->
                vars_add(devaddr, DevAddr, Fields,
                vars_add(deveui, DevEUI, Fields,
                vars_add(appargs, AppArgs, Fields,
                Vars0)));
            #node{devaddr=DevAddr, appargs=AppArgs} ->
                vars_add(devaddr, DevAddr, Fields,
                vars_add(deveui, get_deveui(DevAddr), Fields,
                vars_add(appargs, AppArgs, Fields,
                Vars0)))
        end))),
    lorawan_backend_factory:event(AppID, DeviceOrNode,
        data_to_fields(AppID, Parse, Vars, Event)).

handle_downlink(AppId, Vars) ->
    [#handler{build=Build}=Handler] = mnesia:dirty_read(handlers, AppId),
    send_downlink(Handler,
        Vars,
        maps:get(time, Vars, undefined),
        #txdata{
            confirmed = maps:get(confirmed, Vars, false),
            port = maps:get(port, Vars, undefined),
            data = fields_to_data(AppId, Build, Vars),
            pending = maps:get(pending, Vars, undefined),
            receipt = maps:get(receipt, Vars, undefined)
        }).

fields_to_data(AppId, {_, Fun}, Vars) when is_function(Fun) ->
    try Fun(Vars)
    catch
        Error:Term ->
            lorawan_utils:throw_error({handler, AppId}, {build_failed, {Error, Term}}),
            <<>>
    end;
fields_to_data(_AppId, _Else, Vars) ->
    maps:get(data, Vars, <<>>).

send_downlink(Handler, #{deveui := DevEUI}, undefined, TxData) ->
    case mnesia:dirty_read(devices, DevEUI) of
        [] ->
            {error, {{device, DevEUI}, unknown_deveui}};
        [Device] ->
            [Node] = mnesia:dirty_read(nodes, Device#device.node),
            % standard downlink to an explicit node
            purge_frames(Handler, Node, TxData),
            lorawan_application:store_frame(Device#device.node, TxData)
    end;
send_downlink(Handler, #{deveui := DevEUI}, Time, TxData) ->
    case mnesia:dirty_read(devices, DevEUI) of
        [] ->
            {error, {{device, DevEUI}, unknown_deveui}};
        [Device] ->
            [Node] = mnesia:dirty_read(nodes, Device#device.node),
            % class C downlink to an explicit node
            purge_frames(Handler, Node, TxData),
            lorawan_handler:downlink(Node, Time, TxData)
    end;
send_downlink(Handler, #{devaddr := DevAddr}, undefined, TxData) ->
    case mnesia:dirty_read(nodes, DevAddr) of
        [] ->
            {error, {{node, DevAddr}, unknown_devaddr}};
        [Node] ->
            % standard downlink to an explicit node
            purge_frames(Handler, Node, TxData),
            lorawan_application:store_frame(DevAddr, TxData)
    end;
send_downlink(Handler, #{devaddr := DevAddr}, Time, TxData) ->
    case mnesia:dirty_read(nodes, DevAddr) of
        [] ->
            case mnesia:dirty_read(multicast_channels, DevAddr) of
                [] ->
                    {error, {{node, DevAddr}, unknown_devaddr}};
                [Group] ->
                    % scheduled multicast
                    lorawan_handler:multicast(Group, Time, TxData)
            end;
        [Node] ->
            % class C downlink to an explicit node
            purge_frames(Handler, Node, TxData),
            lorawan_handler:downlink(Node, Time, TxData)
    end;
send_downlink(Handler, #{app := AppID}, undefined, TxData) ->
    % downlink to a group
    filter_group_responses(AppID,
        lists:map(
            fun(#node{devaddr=DevAddr}=Node) ->
                purge_frames(Handler, Node, TxData),
                lorawan_application:store_frame(DevAddr, TxData)
            end,
            lorawan_backend_factory:nodes_with_backend(AppID)));
send_downlink(Handler, #{app := AppID}, Time, TxData) ->
    % class C downlink to a group of devices
    filter_group_responses(AppID,
        lists:map(
            fun(Node) ->
                purge_frames(Handler, Node, TxData),
                lorawan_handler:downlink(Node, Time, TxData)
            end,
            lorawan_backend_factory:nodes_with_backend(AppID)));
send_downlink(_Handler, Else, _Time, _TxData) ->
    lager:error("Unknown downlink target: ~p ", [Else]).

purge_frames(#handler{downlink_expires = <<"superseded">>}=Handler,
        #node{devaddr=DevAddr}=Node, #txdata{port=Port}) ->
    lists:foreach(
        fun
            (#txdata{confirmed=true, receipt=Receipt}) ->
                lorawan_utils:throw_error({node, DevAddr}, downlink_lost),
                send_event(lost, #{receipt => Receipt}, Handler, Node);
            (#txdata{}) ->
                ok
        end,
        lorawan_application:take_previous_frames(DevAddr, Port));
purge_frames(_Handler, _Node, _TxData) ->
    ok.

filter_group_responses(AppID, []) ->
    lager:warning("Group ~w is empty ", [AppID]);
filter_group_responses(_AppID, List) ->
    lists:foldl(
        fun (ok, Right) -> Right;
            (Left, _) -> Left
        end,
        ok, List).

parse_payload(<<"ascii">>, Data) ->
    #{text => Data};
parse_payload(<<"cayenne">>, Data) ->
    #{objects => [cayenne_decode(Data)]};
    %cayenne_decode(Data);
% TODO: IEEE1888 decode parse
% parse_payload(<<"ieee1888">>, Data) ->
%    ieee1888_decode(Data);
parse_payload(None, _Data) when None == <<>>; None == undefined ->
    #{};
parse_payload(Else, _Data) ->
    lager:error("Unknown payload: ~p ", [Else]),
    #{}.

cayenne_decode(Bin) ->
    cayenne_decode(Bin, #{}).

% digital input
cayenne_decode(<<Ch, 0, Val, Rest/binary>>, Acc) ->
    cayenne_decode(Rest, maps:put(<<"object_", (integer_to_binary(Ch))/binary>>, #{id => Ch, type => <<"Digital_in">>, val => Val}, Acc));
% digital output
cayenne_decode(<<Ch, 1, Val, Rest/binary>>, Acc) ->
    cayenne_decode(Rest, maps:put(<<"object_", (integer_to_binary(Ch))/binary>>, #{id => Ch, type => <<"Digital_out">>, val => Val}, Acc));
% analog input
cayenne_decode(<<Ch, 2, Val:16/signed-integer, Rest/binary>>, Acc) ->
    cayenne_decode(Rest, maps:put(<<"object_", (integer_to_binary(Ch))/binary>>, #{id => Ch, type => <<"Analog_in">>, val => Val/100}, Acc));
% analog output
cayenne_decode(<<Ch, 3, Val:16/signed-integer, Rest/binary>>, Acc) ->
    cayenne_decode(Rest, maps:put(<<"object_", (integer_to_binary(Ch))/binary>>, #{id => Ch, type => <<"Analog_out">>, val => Val/100}, Acc));
% Generic sensor
cayenne_decode(<<Ch, 100, Val:16/unsigned-integer, Rest/binary>>, Acc) ->
    cayenne_decode(Rest, maps:put(<<"object_", (integer_to_binary(Ch))/binary>>, #{id => Ch, type => <<"Generic_Sensor">>, val => Val}, Acc));
% illuminance in lx
cayenne_decode(<<Ch, 101, Val:16/unsigned-integer, Rest/binary>>, Acc) ->
    cayenne_decode(Rest, maps:put(<<"object_", (integer_to_binary(Ch))/binary>>, #{id => Ch, type => <<"Iluminance">>, val => Val, unit => <<"lx">>}, Acc));
% presence
cayenne_decode(<<Ch, 102, Val, Rest/binary>>, Acc) ->
    cayenne_decode(Rest, maps:put(<<"object_", (integer_to_binary(Ch))/binary>>, #{id => Ch, type => <<"Presence">>, val => Val}, Acc));
% temperature in °C
cayenne_decode(<<Ch, 103, Val:16/signed-integer, Rest/binary>>, Acc) ->
    cayenne_decode(Rest, maps:put(<<"object_", (integer_to_binary(Ch))/binary>>, #{id => Ch, type => <<"Temperature">>, val => Val/10, unit => <<"°C">>}, Acc));
% humidity in %
cayenne_decode(<<Ch, 104, Val, Rest/binary>>, Acc) ->
    cayenne_decode(Rest, maps:put(<<"object_", (integer_to_binary(Ch))/binary>>, #{id => Ch, type => <<"Humidity">>, val => Val/2, unit => <<"%">>}, Acc));
% power measurement
cayenne_decode(<<Ch, 105, Val:16/unsigned-integer, Rest/binary>>, Acc) ->
    cayenne_decode(Rest, maps:put(<<"object_", (integer_to_binary(Ch))/binary>>, #{id => Ch, type => <<"Power_measurement">>, val => Val/10}, Acc));
% actuation
cayenne_decode(<<Ch, 106, Val:16/signed-integer, Rest/binary>>, Acc) ->
    cayenne_decode(Rest, maps:put(<<"object_", (integer_to_binary(Ch))/binary>>, #{id => Ch, type => <<"Actuation">>, val => Val}, Acc));
% set point
cayenne_decode(<<Ch, 108, Val:16/unsigned-integer, Rest/binary>>, Acc) ->
    cayenne_decode(Rest, maps:put(<<"object_", (integer_to_binary(Ch))/binary>>, #{id => Ch, type => <<"Set_point">>, val => Val}, Acc));
% load control
cayenne_decode(<<Ch, 110, Val:16/unsigned-integer, Rest/binary>>, Acc) ->
    cayenne_decode(Rest, maps:put(<<"object_", (integer_to_binary(Ch))/binary>>, #{id => Ch, type => <<"Load_control">>, val => Val/10}, Acc));
% light control
cayenne_decode(<<Ch, 111, Val:16/unsigned-integer, Rest/binary>>, Acc) ->
    cayenne_decode(Rest, maps:put(<<"object_", (integer_to_binary(Ch))/binary>>, #{id => Ch, type => <<"Light_control">>, val => Val/10}, Acc));
% power control
cayenne_decode(<<Ch, 112, Val:16/unsigned-integer, Rest/binary>>, Acc) ->
    cayenne_decode(Rest, maps:put(<<"object_", (integer_to_binary(Ch))/binary>>, #{id => Ch, type => <<"Power_control">>, val => Val/10}, Acc));
% accelerometer in m/s²
cayenne_decode(<<Ch, 113, X:16/signed-integer, Y:16/signed-integer, Z:16/signed-integer, Rest/binary>>, Acc) ->
    cayenne_decode(Rest, maps:put(<<"object_", (integer_to_binary(Ch))/binary>>, #{id => Ch, type => <<"Accelerometer">>, val => #{x => X/1000, y => Y/1000, z => Z/1000}, unit => #{x => <<"m/s²">>, y => <<"m/s²">>, z => <<"m/s²">>}}, Acc));
% magnetometer and compass
cayenne_decode(<<Ch, 114, X:16/signed-integer, Y:16/signed-integer, Z:16/signed-integer, Rest/binary>>, Acc) ->
    cayenne_decode(Rest, maps:put(<<"object_", (integer_to_binary(Ch))/binary>>, #{id => Ch, type => <<"Magnetometer">>, val => #{x => X/1000, y => Y/1000, z => Z/1000}}, Acc));
% barometer in hPa
cayenne_decode(<<Ch, 115, Val:16/unsigned-integer, Rest/binary>>, Acc) ->
    cayenne_decode(Rest, maps:put(<<"object_", (integer_to_binary(Ch))/binary>>, #{id => Ch, type => <<"Barometer">>, val => Val/10, unit => <<"hPa">>}, Acc));
% voltage in V
cayenne_decode(<<Ch, 116, Val:16/signed-integer, Rest/binary>>, Acc) ->
    cayenne_decode(Rest, maps:put(<<"object_", (integer_to_binary(Ch))/binary>>, #{id => Ch, type => <<"Voltage">>, val => Val/1000, unit => <<"V">>}, Acc));
% current in A
cayenne_decode(<<Ch, 117, Val:16/signed-integer, Rest/binary>>, Acc) ->
    cayenne_decode(Rest, maps:put(<<"object_", (integer_to_binary(Ch))/binary>>, #{id => Ch, type => <<"Current">>, val => Val/1000, unit => <<"A">>}, Acc));
% frequency
cayenne_decode(<<Ch, 118, Val:16/unsigned-integer, Rest/binary>>, Acc) ->
    cayenne_decode(Rest, maps:put(<<"object_", (integer_to_binary(Ch))/binary>>, #{id => Ch, type => <<"Frequency">>, val => Val/10}, Acc));
% percentage in %
cayenne_decode(<<Ch, 120, Val/signed-integer, Rest/binary>>, Acc) ->
    cayenne_decode(Rest, maps:put(<<"object_", (integer_to_binary(Ch))/binary>>, #{id => Ch, type => <<"Percentage">>, val => Val, unit => <<"%">>}, Acc));
% altitude in m
cayenne_decode(<<Ch, 121, Val:16/unsigned-integer, Rest/binary>>, Acc) ->
    cayenne_decode(Rest, maps:put(<<"object_", (integer_to_binary(Ch))/binary>>, #{id => Ch, type => <<"Altitude">>, val => Val/100, unit => <<"m">>}, Acc));
% load in %
cayenne_decode(<<Ch, 122, Val:16/unsigned-integer, Rest/binary>>, Acc) ->
    cayenne_decode(Rest, maps:put(<<"object_", (integer_to_binary(Ch))/binary>>, #{id => Ch, type => <<"Load">>, val => Val/10, unit => <<"%">>}, Acc));
% pressure in Pa
cayenne_decode(<<Ch, 123, Val:16/unsigned-integer, Rest/binary>>, Acc) ->
    cayenne_decode(Rest, maps:put(<<"object_", (integer_to_binary(Ch))/binary>>, #{id => Ch, type => <<"Pressure">>, val => Val/10, unit => <<"Pa">>}, Acc));
% loudness in dB
cayenne_decode(<<Ch, 124, Val:16/unsigned-integer, Rest/binary>>, Acc) ->
    cayenne_decode(Rest, maps:put(<<"object_", (integer_to_binary(Ch))/binary>>, #{id => Ch, type => <<"Loudness">>, val => Val/10, unit => <<"dB">>}, Acc));
% concentration in mol/L
cayenne_decode(<<Ch, 125, Val:16/unsigned-integer, Rest/binary>>, Acc) ->
    cayenne_decode(Rest, maps:put(<<"object_", (integer_to_binary(Ch))/binary>>, #{id => Ch, type => <<"Concentration">>, val => Val/10, unit => <<"mol/L">>}, Acc));
% acidity in g/L
cayenne_decode(<<Ch, 126, Val:16/unsigned-integer, Rest/binary>>, Acc) ->
    cayenne_decode(Rest, maps:put(<<"object_", (integer_to_binary(Ch))/binary>>, #{id => Ch, type => <<"Acidity">>, val => Val/10, unit => <<"g/L">>}, Acc));
% conductivity in S/m
cayenne_decode(<<Ch, 127, Val:16/unsigned-integer, Rest/binary>>, Acc) ->
    cayenne_decode(Rest, maps:put(<<"object_", (integer_to_binary(Ch))/binary>>, #{id => Ch, type => <<"Conductivity">>, val => Val/10, unit => <<"S/m">>}, Acc));
% power in W
cayenne_decode(<<Ch, 128, Val:16/signed-integer, Rest/binary>>, Acc) ->
    cayenne_decode(Rest, maps:put(<<"object_", (integer_to_binary(Ch))/binary>>, #{id => Ch, type => <<"Power">>, val => Val/10 , unit => <<"W">>}, Acc));
% distance in m
cayenne_decode(<<Ch, 130, Val:16/signed-integer, Rest/binary>>, Acc) ->
    cayenne_decode(Rest, maps:put(<<"object_", (integer_to_binary(Ch))/binary>>, #{id => Ch, type => <<"Distance">>, val => Val/10, unit => <<"m">>}, Acc));
% energy in J
cayenne_decode(<<Ch, 131, Val:16/signed-integer, Rest/binary>>, Acc) ->
    cayenne_decode(Rest, maps:put(<<"object_", (integer_to_binary(Ch))/binary>>, #{id => Ch, type => <<"Energy">>, val => Val/10, unit => <<"J">>}, Acc));
% direction in °
cayenne_decode(<<Ch, 132, Val:16/signed-integer, Rest/binary>>, Acc) ->
    %cayenne_decode(Rest, maps:put(<<"Direction">>, Val, Acc));
    cayenne_decode(Rest, maps:put(<<"object_", (integer_to_binary(Ch))/binary>>, #{id => Ch, type => <<"Direction">>, val => Val/1000, unit => <<"°">>}, Acc));
% time in s
cayenne_decode(<<Ch, 133, Val:32/unsigned-integer, Rest/binary>>, Acc) ->
    cayenne_decode(Rest, maps:put(<<"object_", (integer_to_binary(Ch))/binary>>, #{id => Ch, type => <<"Time">>, val => Val/1000, unit => <<"s">>}, Acc));
% gyrometer in rad/s
cayenne_decode(<<Ch, 134, X:16/signed-integer, Y:16/signed-integer, Z:16/signed-integer, Rest/binary>>, Acc) ->
    cayenne_decode(Rest, maps:put(<<"object_", (integer_to_binary(Ch))/binary>>, #{id => Ch, type => <<"Gyrometer">>, val => #{x => X/100, y => Y/100, z => Z/100}, unit => #{x => <<"rad/s">>, y => <<"rad/s">>, z => <<"rad/s">>}}, Acc));
% colour 
cayenne_decode(<<Ch, 135, Val:16/unsigned-integer, Rest/binary>>, Acc) ->
    cayenne_decode(Rest, maps:put(<<"object_", (integer_to_binary(Ch))/binary>>, #{id => Ch, type => <<"Colour">>, val => Val}, Acc));
% gps in ° and m
cayenne_decode(<<Ch, 136, Lat:32/signed-integer, Lon:32/signed-integer, Alt:24/signed-integer, Rest/binary>>, Acc) ->
    cayenne_decode(Rest, maps:put(<<"object_", (integer_to_binary(Ch))/binary>>, #{id => Ch, type => <<"GPS">>, val => #{lat => Lat/1000000, lon => Lon/1000000, alt => Alt/100}, unit => #{lat => <<"°">>, lon => <<"°">>, alt => <<"m">>}}, Acc));
% light gps
cayenne_decode(<<Ch, 236, Lat:24/signed-integer, Lon:24/signed-integer, Alt:24/signed-integer, Rest/binary>>, Acc) ->
    cayenne_decode(Rest, maps:put(<<"object_", (integer_to_binary(Ch))/binary>>, #{id => Ch, type => <<"GPS">>, val => #{lat => Lat/10000, lon => Lon/10000, alt => Alt/100}, unit => #{lat => <<"°">>, lon => <<"°">>, alt => <<"m">>}}, Acc));
% positioner 
cayenne_decode(<<Ch, 137, Val/unsigned-integer, Rest/binary>>, Acc) ->
     cayenne_decode(Rest, maps:put(<<"object_", (integer_to_binary(Ch))/binary>>, #{id => Ch, type => <<"Positioner">>, val => Val}, Acc));
% on/off switch 
cayenne_decode(<<Ch, 142, Val/unsigned-integer, Rest/binary>>, Acc) ->
     cayenne_decode(Rest, maps:put(<<"object_", (integer_to_binary(Ch))/binary>>, #{id => Ch, type => <<"Switch">>, val => Val}, Acc));
% level control 
cayenne_decode(<<Ch, 143, Val/unsigned-integer, Rest/binary>>, Acc) ->
     cayenne_decode(Rest, maps:put(<<"object_", (integer_to_binary(Ch))/binary>>, #{id => Ch, type => <<"Level_control">>, val => Val}, Acc));
% up/down control 
cayenne_decode(<<Ch, 144, Val/signed-integer, Rest/binary>>, Acc) ->
     cayenne_decode(Rest, maps:put(<<"object_", (integer_to_binary(Ch))/binary>>, #{id => Ch, type => <<"Control">>, val => Val}, Acc));
% multiple axis joystick
cayenne_decode(<<Ch, 145, X:16/signed-integer, Y:16/signed-integer, Z:16/signed-integer, Rest/binary>>, Acc) ->
     cayenne_decode(Rest, maps:put(<<"object_", (integer_to_binary(Ch))/binary>>, #{id => Ch, type => <<"Multiple_axis_joystick">>, val => #{x => X/100, y => Y/100, z => Z/100}}, Acc));
% rate in 1/s
cayenne_decode(<<Ch, 146, Val/unsigned-integer, Rest/binary>>, Acc) ->
    cayenne_decode(Rest, maps:put(<<"object_", (integer_to_binary(Ch))/binary>>, #{id => Ch, type => <<"Rate">>, val => Val/10, unit => <<"1/s">>}, Acc));
% push button
cayenne_decode(<<Ch, 147, Val/unsigned-integer, Rest/binary>>, Acc) ->
    cayenne_decode(Rest, maps:put(<<"object_", (integer_to_binary(Ch))/binary>>, #{id => Ch, type => <<"Push_button">>, val => Val}, Acc));
% multistate selector
cayenne_decode(<<Ch, 148, Val:16/unsigned-integer, Rest/binary>>, Acc) ->
    cayenne_decode(Rest, maps:put(<<"object_", (integer_to_binary(Ch))/binary>>, #{id => Ch, type => <<"Multistate_selector">>, val => Val}, Acc));
% moisture in g/m³
cayenne_decode(<<Ch, 170, Val/unsigned-integer, Rest/binary>>, Acc) ->
    cayenne_decode(Rest, maps:put(<<"object_", (integer_to_binary(Ch))/binary>>, #{id => Ch, type => <<"Moisture">>, val => Val/2, unit => <<"g/m³">>}, Acc));
% smoke in µg/m³
cayenne_decode(<<Ch, 171, Val:16/unsigned-integer, Rest/binary>>, Acc) ->
    cayenne_decode(Rest, maps:put(<<"object_", (integer_to_binary(Ch))/binary>>, #{id => Ch, type => <<"Smoke">>, val => Val/10, unit => <<"µg/m³">>}, Acc));
% alcohol in mol/L
cayenne_decode(<<Ch, 172, Val:16/unsigned-integer, Rest/binary>>, Acc) ->
    cayenne_decode(Rest, maps:put(<<"object_", (integer_to_binary(Ch))/binary>>, #{id => Ch, type => <<"Alcohol">>, val => Val/10, unit => <<"mol/L">>}, Acc));
% LPG (liquid petroleum gas) in m³
cayenne_decode(<<Ch, 173, Val:16/unsigned-integer, Rest/binary>>, Acc) ->
    cayenne_decode(Rest, maps:put(<<"object_", (integer_to_binary(Ch))/binary>>, #{id => Ch, type => <<"LPG">>, val => Val/10, unit => <<"m³">>}, Acc));
% carbon monoxide in ppm
cayenne_decode(<<Ch, 174, Val:16/unsigned-integer, Rest/binary>>, Acc) ->
    cayenne_decode(Rest, maps:put(<<"object_", (integer_to_binary(Ch))/binary>>, #{id => Ch, type => <<"Carbon_monoxide">>, val => Val/10, unit => <<"ppm">>}, Acc));
% carbon dioxide in ppm
cayenne_decode(<<Ch, 175, Val:16/unsigned-integer, Rest/binary>>, Acc) ->
    cayenne_decode(Rest, maps:put(<<"object_", (integer_to_binary(Ch))/binary>>, #{id => Ch, type => <<"Carbon_Dioxide">>, val => Val/10, unit => <<"ppm">>}, Acc));
% air quality in ppm
cayenne_decode(<<Ch, 176, Val:16/unsigned-integer, Rest/binary>>, Acc) ->
    cayenne_decode(Rest, maps:put(<<"object_", (integer_to_binary(Ch))/binary>>, #{id => Ch, type => <<"Air_quality">>, val => Val, unit => <<"ppm">>}, Acc));
% collision
cayenne_decode(<<Ch, 177, Val:16/unsigned-integer, Rest/binary>>, Acc) ->
    cayenne_decode(Rest, maps:put(<<"object_", (integer_to_binary(Ch))/binary>>, #{id => Ch, type => <<"Collision">>, val => Val/10}, Acc));
% dust in mg/m³
cayenne_decode(<<Ch, 178, Val:16/unsigned-integer, Rest/binary>>, Acc) ->
    cayenne_decode(Rest, maps:put(<<"object_", (integer_to_binary(Ch))/binary>>, #{id => Ch, type => <<"Dust">>, val => Val/10, unit => <<"mg/m³">>}, Acc));
% fire
cayenne_decode(<<Ch, 179, Val:16/unsigned-integer, Rest/binary>>, Acc) ->
    cayenne_decode(Rest, maps:put(<<"object_", (integer_to_binary(Ch))/binary>>, #{id => Ch, type => <<"Fire">>, val => Val/10}, Acc));
% uv in mW/cm²
cayenne_decode(<<Ch, 180, Val:16/unsigned-integer, Rest/binary>>, Acc) ->
    cayenne_decode(Rest, maps:put(<<"object_", (integer_to_binary(Ch))/binary>>, #{id => Ch, type => <<"UV">>, val => Val/10, unit => <<"mW/cm²">>}, Acc));
% battery in %
cayenne_decode(<<Ch, 181, Val, Rest/binary>>, Acc) ->
    cayenne_decode(Rest, maps:put(<<"object_", (integer_to_binary(Ch))/binary>>, #{id => Ch, type => <<"Battery">>, val => Val/2, unit => <<"%">>}, Acc));
% velocity in km/h
cayenne_decode(<<Ch, 182, Val:16/signed-integer, Rest/binary>>, Acc) ->
    cayenne_decode(Rest, maps:put(<<"object_", (integer_to_binary(Ch))/binary>>, #{id => Ch, type => <<"Velocity">>, val => Val/100, unit => <<"km/h">>}, Acc));
cayenne_decode(<<>>, Acc) ->
    Acc.
        
%add_field(Num, String, Value, Acc) ->
%    maps:put(<<"field ", (integer_to_binary(Num))/binary>>, String, Value, Acc).


-include_lib("eunit/include/eunit.hrl").

% https://github.com/myDevicesIoT/cayenne-docs/blob/master/docs/LORA.md
%cayenne_test_()-> [
%    ?_assertEqual(#{<<"field3">> => 27.2, <<"field5">> => 25.5},
%        cayenne_decode(lorawan_utils:hex_to_binary(<<"03670110056700FF">>))),
%    ?_assertEqual(#{<<"field1">> => -4.1},
%        cayenne_decode(lorawan_utils:hex_to_binary(<<"0167FFD7">>))),
%    ?_assertEqual(#{<<"field6">> => #{x => 1.234, y => -1.234, z => 0.0}},
%        cayenne_decode(lorawan_utils:hex_to_binary(<<"067104D2FB2E0000">>))),
%    ?_assertEqual(#{<<"field1">> => #{lat => 42.3519, lon => -87.9094, alt => 10.0}},
%        cayenne_decode(lorawan_utils:hex_to_binary(<<"018806765ff2960a0003e8">>)))
%].

% end of file
