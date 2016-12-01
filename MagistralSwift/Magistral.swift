//
//  magistral.swift
//  ios
//
//  Created by rizarse on 22/07/16.
//  Copyright © 2016 magistral.io. All rights reserved.
//

import Foundation

import SwiftMQTT
import SwiftyJSON
import Alamofire

public class Magistral : IMagistral {
    
    private var pubKey : String, subKey : String, secretKey : String, cipher : String?;
    private var ssl : Bool?;
    
    private var active = false;
    
    private var host : String = "app.magistral.io";
    
    private var mqtt : MqttClient?;
    
    private var init_indexes : [String : [Int : UInt64]]  = [ : ];
    private var settings : [String : [[String : String]]] = [ : ];
    
    public typealias Connected = (Bool, Magistral) -> Void
    
    convenience init(pubKey : String, subKey : String, secretKey : String, connected : Connected?) {
        self.init(pubKey : pubKey, subKey : subKey, secretKey : secretKey, cipher : "", connected : connected);
    }
    
    public func setHost(host : String) {
        self.host = host;
    }
    
    public func setCipher(cipher: String) {
        self.cipher = cipher;
    }
    
    public required init(pubKey : String, subKey : String, secretKey : String, cipher : String, connected : Connected? ) {
        
        self.pubKey = pubKey;
        self.subKey = subKey;
        self.secretKey = secretKey;
        
        if (cipher != "") { self.cipher = cipher; }
        
        self.connectionPoints(callback: { token, settings in
            self.settings = settings;
            
            self.initMqtt(token: token, connected: { status, magistral in
                connected!(status, magistral);
            })
        });
    }
    
//    private func indexes(callback : @escaping (_ indexes : [ String : [Int : UInt64]]) -> Void) {
//        let baseURL = "https://" + self.host + "/api/magistral/data/indexes"
//        
//        let user = self.pubKey + "|" + self.subKey;
//        
//        let params : Parameters = [ : ]
//        
//        RestApiManager.sharedInstance.makeHTTPGetRequest(path: baseURL, parameters: params, user: user, password : self.secretKey, onCompletion: { json, err in
//            do {
//                let indexes = try JsonConverter.sharedInstance.handleIndexes(json: json);
//                for i in indexes {
//                    
//                    if (self.init_indexes[i.topic()] != nil) {
//                        self.init_indexes[i.topic()]?[i.channel()] = i.index()
//                    } else {
//                        self.init_indexes[i.topic()] = [ : ]
//                        self.init_indexes[i.topic()]?[i.channel()] = i.index()
//                    }
//                }
//                
//                callback(self.init_indexes);
//            } catch {
//                callback(self.init_indexes);
//            }
//        })
//    }
    
    private func initMqtt(token : String, connected : Connected?) {
        
        mqtt = MqttClient(host: self.host, port: 8883, clientID: "magistral.mqtt.gw." + token, cleanSession: false, keepAlive: 30, useSSL: true)
        
        mqtt?.username = self.pubKey + "|" + self.subKey;
        mqtt?.password = self.secretKey
        
        mqtt?.lastWillMessage = MQTTPubMsg(topic: "presence/" + self.pubKey + "/" + token, payload: Data(bytes: [0]), retain: true, QoS: MQTTQoS.atLeastOnce);
        mqtt?.delegate = mqtt;

        mqtt?.addMessageListener({ ref, message in
            
            if let groupListeners = self.lstMap[message.topic()] {
                for (group, listener) in groupListeners {
                    
                    let baseURL = "https://" + self.host + "/api/magistral/data/read"
                    
                    let user = self.pubKey + "|" + self.subKey;
                    
                    var params : Parameters = [ : ]
                    
                    params["group"] = group as AnyObject?;
                    params["topic"] = message.topic() as AnyObject?;
                    params["channel"] = message.channel() as AnyObject?;
                    
                    params["index"] = String(message.index()) as AnyObject?;
                    
                    RestApiManager.sharedInstance.makeHTTPGetRequest(path: baseURL, parameters: params, user: user, password : self.secretKey, onCompletion: { json, err in
                        do {
                            let messages = try JsonConverter.sharedInstance.handleMessageEvent(json: json);
                            
                            for m in messages {                                
//                                listener(m, nil)
                                
                                if let chixs = self.init_indexes[m.topic()] {
                                    if let ixs = chixs[m.channel()] {
                                        if m.index() > ixs {
                                            listener(m, nil)
                                            self.init_indexes[m.topic()]?[m.channel()] = m.index()
                                        }
                                    }
                                } else {
                                    listener(m, nil)
                                    self.init_indexes[m.topic()] = [ : ]
                                    self.init_indexes[m.topic()]?[m.channel()] = m.index()
                                }
                            }
                        } catch {
                            let eve = Message(topic: "null", channel: 0, msg: [], index: 0, timestamp: 0)
                            listener(eve, MagistralException.conversionError)
                        }
                    })
                }
            }
        });
        
        mqtt?.connect(completion: { mqtt_connected, error in
            if (mqtt_connected) {
                self.mqtt?.subscribe(to: "exceptions", delivering: .atLeastOnce, completion: nil)
                self.mqtt?.publish(Data([1]), in: "presence/" + self.pubKey + "/" + token, delivering: .atLeastOnce, retain: true, completion: nil)
                self.active = true
                connected!(self.active, self);
            }
        }, disconnect: { session in
            if (self.active) {
                print("Connection dropped -> reconnection in 5 sec.")                
                DispatchQueue.main.asyncAfter(deadline: .now() + .seconds(5)) {
                    session.connect(completion: { mqtt_connected, error in
                        if (mqtt_connected) {
                            self.mqtt?.subscribe(to: "exceptions", delivering: .atLeastOnce, completion: nil)
                            self.mqtt?.publish(Data([1]), in: "presence/" + self.pubKey + "/" + token, delivering: .atLeastOnce, retain: true, completion: nil)
                            self.active = true
                            connected!(self.active, self);
                        }
                    });
                }
            }            
        }, socketerr: { session in
            if (self.active) {
                print("Socket error")
            }
        })
    }
    
    private func connectionPoints(callback : @escaping (_ token : String, _ settings : [ String : [[String : String]] ]) -> Void) {
        
        let baseURL = "https://" + self.host + "/api/magistral/net/connectionPoints"
        
        let user = self.pubKey + "|" + self.subKey;
        
        RestApiManager.sharedInstance.makeHTTPGetRequest(path: baseURL, parameters: [:], user: user, password : self.secretKey, onCompletion: { json, err in
            let cps : (String, [ String : [[String : String]] ]) = JsonConverter.sharedInstance.connectionPoints(json: json);
            callback(cps.0, cps.1)
        })
    }
    
//  PUBLISH
    
    public func publish(_ topic : String, msg : [UInt8], callback : io.magistral.client.pub.Callback?) throws {
        try self.publish(topic, channel: -1, msg: msg, callback: callback);
    }
    
    public func publish(_ topic : String, channel : Int, msg : [UInt8], callback : io.magistral.client.pub.Callback?) throws {
        mqtt?.publish(topic, channel: channel, msg: msg, callback: { ack, error in
            callback?(ack, error);
        })
    }

//  SUBSCRIBE
    
    private var lstMap : [ String : [String : io.magistral.client.sub.NetworkListener]] = [ : ];
    
    public func subscribe(_ topic : String, listener : @escaping io.magistral.client.sub.NetworkListener, callback : io.magistral.client.sub.Callback?) throws {
        try self.subscribe(topic, group : "default", channel : -1, listener : listener, callback: callback);
    }
    
    public func subscribe(_ topic : String, channel : Int, listener : @escaping io.magistral.client.sub.NetworkListener, callback : io.magistral.client.sub.Callback?) throws {
         try self.subscribe(topic, group : "default", channel : channel, listener : listener, callback: callback);
    }
    
    public func subscribe(_ topic : String, group : String, listener : @escaping io.magistral.client.sub.NetworkListener, callback : io.magistral.client.sub.Callback?) throws {
        try self.subscribe(topic, group : group, channel : -1, listener : listener, callback: callback);
    }
    
    public func subscribe(_ topic : String, group : String, channel : Int, listener : @escaping io.magistral.client.sub.NetworkListener, callback : io.magistral.client.sub.Callback?) throws {

        let ch = (channel < -1) ? -1 : channel;
        
        self.mqtt?.subscribe(topic, channel: ch, group: group, qos: .atLeastOnce, callback : { meta, err in
            callback?(meta, err)
        })
        
        if let listenerGroups = self.lstMap[topic] {
            if listenerGroups[group] == nil {
                self.lstMap[topic]![group] = listener;
            }
        } else {
            self.lstMap[topic] = [ group : listener ]
        }
    }
    
    public func unsubscribe(_ topic : String, callback : io.magistral.client.sub.Callback?) throws {
        self.mqtt?.unsubscribe(topic, callback: { meta, err in
            callback?(io.magistral.client.sub.SubMeta(topic: meta.topic(), channel: meta.channel(), group: meta.group(), endPoints: meta.endPoints()), err);
        })
    }
    
    public func unsubscribe(_ topic : String, channel : Int, callback : io.magistral.client.sub.Callback?) throws {
        self.mqtt?.unsubscribe(topic, callback: { meta, err in
            callback?(io.magistral.client.sub.SubMeta(topic: meta.topic(), channel: meta.channel(), group: meta.group(), endPoints: meta.endPoints()), err);
        })
    }
    
//  TOPICS
    
    public func topics(_ callback : @escaping io.magistral.client.topics.Callback) throws {
        try permissions({ perms, err in
            var topics : [io.magistral.client.topics.TopicMeta] = []
            
            for p in perms {
                topics.append(io.magistral.client.topics.TopicMeta(topic: p.topic(), channels: p.channels()))
            }
            
            callback(topics, err == nil ? nil : MagistralException.fetchTopicsError);
        });
    }
    
    public func topic(_ topic : String, callback : @escaping io.magistral.client.topics.Callback) throws {
        try permissions(topic, callback: { perms, err in
            var topics : [io.magistral.client.topics.TopicMeta] = [];
            
            for p in perms {
                topics.append(io.magistral.client.topics.TopicMeta(topic: p.topic(), channels: p.channels()))
            }
            
            callback(topics, err == nil ? nil : MagistralException.fetchTopicsError);
        });
    }
    
    // ACCESS CONTROL
    
    public func permissions(_ callback : @escaping io.magistral.client.perm.Callback) throws {
        let baseURL = "https://" + self.host + "/api/magistral/net/permissions"
        
        let user = self.pubKey + "|" + self.subKey;
        
        RestApiManager.sharedInstance.makeHTTPGetRequest(path: baseURL, parameters: [:], user: user, password : self.secretKey, onCompletion: { json, err in
            do {
                let permissions : [io.magistral.client.perm.PermMeta] = try JsonConverter.sharedInstance.handle(json: json);
                callback(permissions, err == nil ? nil : MagistralException.permissionFetchError);
            } catch MagistralException.historyInvocationError {
                
            } catch {
                
            }
        })
    }
    
    public func permissions(_ topic: String, callback : @escaping io.magistral.client.perm.Callback) throws {
        let baseURL = "https://" + self.host + "/api/magistral/net/permissions"
        
        var params : Parameters = [ : ]
        params["topic"] = topic;
        
        let user = self.pubKey + "|" + self.subKey;
        
        RestApiManager.sharedInstance.makeHTTPGetRequest(path: baseURL, parameters: params, user: user, password : self.secretKey, onCompletion: { json, err in
            do {
                let permissions : [io.magistral.client.perm.PermMeta] = try JsonConverter.sharedInstance.handle(json: json);
                callback(permissions, err == nil ? nil : MagistralException.permissionFetchError);
            } catch {
            
            }
        })
    }
    
    // PERMISSIONS - GRANT
    
    public func grant(_ user: String, topic: String, read: Bool, write: Bool, callback : io.magistral.client.perm.Callback?) throws {
        try self.grant(user, topic: topic, channel: -1, read: read, write: write, ttl: -1, callback: callback);
    }
    
    public func grant(_ user: String, topic: String, read: Bool, write: Bool, ttl: Int, callback : io.magistral.client.perm.Callback?) throws {
        try self.grant(user, topic: topic, channel: -1, read: read, write: write, ttl: ttl, callback: callback);
    }
    
    public func grant(_ user: String, topic: String, channel: Int, read: Bool, write: Bool, callback : io.magistral.client.perm.Callback?) throws {
        try self.grant(user, topic: topic, channel: channel, read: read, write: write, ttl: -1, callback: callback);
    }
    
    public func grant(_ user: String, topic: String, channel: Int, read: Bool, write: Bool, ttl: Int, callback : io.magistral.client.perm.Callback?) throws {
        
        let baseURL = "https://" + self.host + "/api/magistral/net/grant"
        
        var params : Parameters = [ : ]
        params["user"] = user;
        params["topic"] = topic;
        
        if (channel > -1) {
            params["channel"] = channel;
        }
        
        params["read"] = String(read);
        params["write"] = String(write);
        
        if (ttl > -1) {
            params["ttl"] = ttl;
        }
        
        let auth = self.pubKey + "|" + self.subKey;
        
        RestApiManager.sharedInstance.makeHTTPPutRequestText(baseURL, parameters: params, user: auth, password : self.secretKey, onCompletion: { text, err in
            if (callback != nil && err == nil) {
                
                let baseURL = "https://" + self.host + "/api/magistral/net/user_permissions"
                
                RestApiManager.sharedInstance.makeHTTPGetRequest(path: baseURL, parameters: [ "userName" : user], user: auth, password : self.secretKey, onCompletion: { json, err in
                    do {
                        let permissions : [io.magistral.client.perm.PermMeta] = try JsonConverter.sharedInstance.handle(json: json);
                        callback?(permissions, err == nil ? nil : MagistralException.permissionFetchError);
                    } catch {
                    }
                })
            }
        })
    }
    
    // PERMISSIONS - REVOKE
    
    public func revoke(_ user: String, topic: String, callback : io.magistral.client.perm.Callback?) throws {
        try revoke(user, topic: topic, channel: -1, callback: callback);
    }

    public func revoke(_ user: String, topic: String, channel: Int, callback : io.magistral.client.perm.Callback?) throws {
        let baseURL = "https://" + self.host + "/api/magistral/net/revoke"
        
        var params : Parameters = [ : ]
        params["user"] = user;
        params["topic"] = topic;
        
        if (channel > -1) {
            params["channel"] = channel;
        }
        
        let auth = self.pubKey + "|" + self.subKey;
        
        RestApiManager.sharedInstance.makeHTTPDeleteRequestText(baseURL, parameters: params, user: auth, password: self.secretKey) { text, err in
            if (callback != nil && err == nil) {
                
                let baseURL = "https://" + self.host + "/api/magistral/net/user_permissions"
                
                RestApiManager.sharedInstance.makeHTTPGetRequest(path: baseURL, parameters: [ "userName" : user], user: auth, password : self.secretKey, onCompletion: { json, err in
                    do {
                        let permissions : [io.magistral.client.perm.PermMeta] = try JsonConverter.sharedInstance.handle(json: json);
                        callback?(permissions, err == nil ? nil : MagistralException.permissionFetchError);
                    } catch {
                    }
                })
            }
        }
    }
    
    // HISTORY
    
    public func history(_ topic: String, channel: Int, count: Int, callback : @escaping io.magistral.client.data.Callback) throws {
        try self.history(topic, channel: channel, start: UInt64(0), count: count, callback: callback)
    }
    
    public func history(_ topic: String, channel: Int, start: UInt64, count: Int, callback : @escaping io.magistral.client.data.Callback) throws {
        let baseURL = "https://" + self.host + "/api/magistral/data/history"
        
        var params : Parameters = [ : ]
        
        params["topic"] = topic;
        params["channel"] = channel;
        params["count"] = count;
        
        if (start > 0) {
            params["start"] = start
        }
        
        let user = self.pubKey + "|" + self.subKey;
        
        RestApiManager.sharedInstance.makeHTTPGetRequest(path: baseURL, parameters: params, user: user, password : self.secretKey, onCompletion: { json, err in
            do {
                let history : io.magistral.client.data.History = try JsonConverter.sharedInstance.handle(json: json);
                callback(history, err == nil ? nil : MagistralException.historyInvocationError);
            } catch MagistralException.historyInvocationError {
                let history = io.magistral.client.data.History(messages: [Message]());
                callback(history, MagistralException.historyInvocationError)
            } catch {
                
            }
        })
    }
    
    public func history(_ topic: String, channel: Int, start: UInt64, end: UInt64, callback : @escaping io.magistral.client.data.Callback) throws {
        let baseURL = "https://" + self.host + "/api/magistral/data/historyForPeriod"
        
        var params : Parameters = [ : ]
        
        params["topic"] = topic;
        params["channel"] = channel;
        
        params["start"] = start;
        params["end"] = end;
        
        let user = self.pubKey + "|" + self.subKey;
        
        RestApiManager.sharedInstance.makeHTTPGetRequest(path: baseURL, parameters: params, user: user, password : self.secretKey, onCompletion: { json, err in
            do {
                let history : io.magistral.client.data.History = try JsonConverter.sharedInstance.handle(json: json);
                callback(history, err == nil ? nil : MagistralException.historyInvocationError);
            } catch MagistralException.historyInvocationError {
                let history = io.magistral.client.data.History(messages: [Message]());
                callback(history, MagistralException.historyInvocationError)
            } catch {
                
            }
        })
    }
    
    public func close() {        
        mqtt?.disconnect();
        self.active = false;
    }
}