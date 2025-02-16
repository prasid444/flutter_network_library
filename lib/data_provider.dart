

import 'dart:convert';
import 'package:flutter/cupertino.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_network_library/config.dart';
import 'package:flutter_network_library/domain.dart';
import 'package:flutter_network_library/flutter_network_library.dart';
import 'package:flutter_network_library/network_request_maker.dart';
import 'package:flutter_network_library/persistor.dart';
import 'package:hive/hive.dart';
import 'package:hive_flutter/hive_flutter.dart';


typedef ResponseCallback(Response res);
typedef Widget RESTBuilder(Response response);

class RESTListenableBuilder extends ValueListenableBuilder{
/// Creates a listenable builder that listens to the changes do provided RESTExecutor's domain

  final RESTExecutor executor;

  // The RESTExecutor object for this builder

  RESTListenableBuilder({
    this.executor,
    RESTBuilder builder,
    
    bool exact = false
    
  }): super(valueListenable:executor.getListenable(exact),builder:(_,__,___)=>builder(executor.response));
}

class RESTWidget extends RESTListenableBuilder{
  RESTWidget({
    @required RESTExecutor executor,
    @required RESTBuilder builder,
    bool exact =false
  }): super(executor: executor,builder:builder,exact:exact);
}

class RESTExecutor{
  String method;
  String domain;
  String label;
  bool includeParamsInKey;
  Map<String,dynamic> params;
  List<String> identifiers;
  Map<String,String> headers;

  int cacheForSeconds;
  int retryAfterSeconds;


  ResponseCallback successCallback;
  ResponseCallback errorCallback;

  Persistor cache;

  NetworkRequestMaker requestMaker;


  static Map<String,Domain> domains;
  static Map<String,Set<String>> domainState;
  

  static int cacheForSecondsAll = 60;
  static int retryAfterSecondsAll = 15;

  static initialize(NetworkConfig config,Map<String,Domain> domains)async{

    RESTExecutor.domains = domains;

    if(config.cacheForSeconds!=null)
    RESTExecutor.cacheForSecondsAll = config.cacheForSeconds;

    await Persistor.initialize();
    await NetworkRequestMaker.initialize(config);

    domainState = {};
   domains.forEach((key, value) {
     domainState[key] = {};
   });
    
  }
  

  static RESTExecutor from(RESTExecutor executor){
    return RESTExecutor(
      domain: executor.domain,
      label: executor.label,
      params: executor.params,
      headers: executor.headers,
      includeParamsInKey: executor.includeParamsInKey,
      identifiers: executor.identifiers,
      method: executor.method,
      successCallback: executor.successCallback,
      errorCallback: executor.errorCallback,
      cacheForSeconds: executor.cacheForSeconds,
      retryAfterSeconds: executor.retryAfterSeconds
      
    );
  }

  RESTExecutor(
    {
      @required this.domain,
      @required this.label,
      this.method = 'GET',
      this.params,
      this.includeParamsInKey = true,
      this.identifiers = const [],
      this.headers,
      this.successCallback,
      this.errorCallback,
      this.cacheForSeconds,
      this.retryAfterSeconds
    }
  ){

    assert(domains.keys.contains(domain));

    requestMaker = NetworkRequestMaker();
    cache = Persistor(domain);

    // cache.init(getKey());
  }

  static Future<void> clearCache()=>Persistor.clear();

  void delete(){
    method = 'DELETE';
  }

  void post(){
    method = 'POST';
  }

  void setParams(Map<String,dynamic> params){
        this.params = params??{};
  }

  void setHeaders(Map<String,String> headers){
    this.headers = headers;
  }

  ValueListenable<Box<dynamic>> getListenable([bool exact=false]){
    return cache.getBox().listenable(keys: exact?[getKey()]:null);
  }

  Response watch(BuildContext context,{bool exact = false}){
    
    getListenable(exact).addListener(() {

      (context as Element).markNeedsBuild();

    });
    return response;
  }


  static refetchDomain(String domain){
    domainState[domain] = {};

    RESTExecutor(domain: domain,label: 'label').read();
  }

  Response get response => read(true);

  Response read([bool active = true]){

    if(!active)
     return cache.read(getKey());

    if(

      domains[domain].type==DomainType.network
      &&
      method=='GET'
      &&
      !cache.read(getKey()).fetching
      &&
      (
      (!domainState[domain].contains(getKey()))
      
      ||

      (!cache.getFreshStatus(
        getKey(), 
        cacheForSeconds??domains[domain].cacheForSeconds??RESTExecutor.cacheForSecondsAll,
        retryAfterSeconds??domains[domain].retryAfterSeconds??RESTExecutor.retryAfterSecondsAll
        ))
      )
      ){

        domainState[domain].add(getKey());
        execute();
    }

    return cache.read(getKey());
  }


  String getKey(){
      if (includeParamsInKey) {
      return '$method$label$identifiers${params.toString()?.hashCode}${headers.toString()?.hashCode}';
    }
    return '$method$label$identifiers${headers.toString()?.hashCode}';
  }

   Future<Response> execute({
    Map<String,dynamic> data,
    bool mutation

  }) async{
    switch(domains[domain].type){

      case DomainType.network:
      return networkExecute(data,mutation);
      break;

      default:
      return basicExecute(data);
      break;

    }
  }

  Future<Response> basicExecute(Map<String,dynamic> data)async{

    if(data == null)
    await cache.end(getKey());
    else
    await cache.complete(getKey(), data: data, success: true);

    if(successCallback!=null && response.success){
      successCallback(cache.read(getKey()));
    }

    return cache.read(getKey());
  }

  Future<Response> networkExecute(Map<String,dynamic> data,bool mutation)async{
    
    cache.start(getKey());

    NetworkResponse response = await requestMaker.execute(

      path: domains[domain].path[label],
      query: params,
      identifiers: identifiers,
      data: data,
      method: method,
      headers: headers
    );

    if(response.statusCode>=400){
    }

    try{
      dynamic decoded = jsonDecode(response.data);

      
    await cache.complete(getKey(),
    success: response.success,
    rawData: response.data,
    data: decoded,
    statusCode: response.statusCode,
    );
    }catch(e){
     await cache.complete(getKey(),
          success: response.success,
          rawData: response.data,
          data: {},
          statusCode: response.statusCode
          );
    }

    if(successCallback!=null && response.success){

      successCallback(cache.read(getKey()));
    }

    else if(errorCallback!=null && !response.success)
      errorCallback(cache.read(getKey()));


    if(
      mutation??
      (
      method?.toUpperCase()!='GET' && response.success
      )
      ){
      domainState[domain] = {};
    }

    if(
      method=='GET'
      &&
      false// response.isAuthError
      &&
      (domainState[domain].contains(getKey()))
      ){
        domainState[domain].remove(getKey());
      }


    await cache.end(getKey());

    return cache.read(getKey());
    
  }



}
