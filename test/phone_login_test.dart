import 'dart:io';
import 'package:auralis/app.dart';
import 'package:auralis/telegram/phone_login.dart';
import 'package:auralis/telegram/td_transport.dart';
import 'package:auralis/telegram/telegram_service.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'fakes.dart';

const countryData={'countries':[
  {'country_code':'BD','name':'Bangladesh','english_name':'Bangladesh','calling_codes':['880']},
  {'country_code':'JP','name':'Japan','english_name':'Japan','calling_codes':['81']},
  {'country_code':'US','name':'United States','english_name':'United States','calling_codes':['1']},
  {'country_code':'CA','name':'Canada','english_name':'Canada','calling_codes':['1']},
  {'country_code':'IT','name':'Italy','english_name':'Italy','calling_codes':['39']},
  {'country_code':'XX','name':'Hidden','english_name':'Hidden','calling_codes':['999'],'is_hidden':true},
]};

void codeState(FakeTd td,String number)=>td.events.add({'@type':'updateAuthorizationState','authorization_state':{
  '@type':'authorizationStateWaitCode','code_info':{'phone_number':number},
}});

void main() {
  late Directory directory;
  setUp(() async {directory=await Directory.systemTemp.createTemp('auralis-phone-');});
  tearDown(() async {await directory.delete(recursive:true);});

  test('country list supports shared calling codes, search and hidden entries',() {
    final countries=PhoneCountry.fromResponse(countryData);
    expect(countries.where((c)=>c.callingCode=='1'),hasLength(2));
    expect(countries.any((c)=>c.iso=='XX'),isFalse);
    expect(countries.singleWhere((c)=>c.matches('+880')).iso,'BD');
    expect(countries.singleWhere((c)=>c.matches('jp')).englishName,'Japan');
  });
  test('national numbers get one prefix while pasted international numbers keep theirs',() {
    const bd=PhoneCountry('BD','Bangladesh','Bangladesh','880');
    const italy=PhoneCountry('IT','Italy','Italy','39');
    expect(internationalLoginNumber('1712 345 678',country:bd),'+8801712345678');
    expect(internationalLoginNumber('+81 (90) 1234-5678',country:bd),'+819012345678');
    expect(internationalLoginNumber('0081 90 1234 5678'),'+819012345678');
    expect(internationalLoginNumber('0612345678',country:italy),'+390612345678');
    for(final number in ['','12345','+0 12345','+1234567890123456','+880words']) {
      expect(()=>internationalLoginNumber(number),throwsFormatException);
    }
  });
  test('editing a pending login reuses TDLib, keeps old number on rejection and never persists phone',() async {
    final td=FakeTd(),vault=MemoryVault();
    final service=TelegramService(directory,vault,transport:td,applicationApiId:12345,applicationApiHash:'a'*32);
    addTearDown(service.shutdown);
    await service.start();td.auth('authorizationStateWaitPhoneNumber');
    await service.submit('+8801712345678');codeState(td,'8801712345678');
    expect(service.authenticationPhoneNumber,'+8801712345678');
    td.onRequest=(r) async {if(r['@type']=='setAuthenticationPhoneNumber') throw TdException(429,'wait');return null;};
    await service.changeLoginPhoneNumber('+819012345678');
    expect(service.error,contains('429'));expect(service.authenticationPhoneNumber,'+8801712345678');
    expect(service.state,'authorizationStateWaitCode');
    td.onRequest=null;await service.changeLoginPhoneNumber('+819012345678');
    expect(service.error,isNull);expect(service.authenticationPhoneNumber,'+819012345678');
    expect(td.requests.where((r)=>r['@type']=='setTdlibParameters'),hasLength(1));
    expect(td.requests.any((r)=>r['@type']=='logOut'),isFalse);
    expect(vault.data.keys.toSet(),{'apiId','apiHash','databaseKey'});
    td.auth('authorizationStateReady');
    expect(service.authenticationPhoneNumber,isNull);
    final calls=td.requests.where((r)=>r['@type']=='setAuthenticationPhoneNumber').length;
    await service.changeLoginPhoneNumber('+12025550123');
    expect(td.requests.where((r)=>r['@type']=='setAuthenticationPhoneNumber'),hasLength(calls));
  });

  testWidgets('country selection and code-page correction send only the chosen phone number', (tester) async {
    final td=FakeTd(),vault=MemoryVault();
    td.onRequest=(r) async {
      if(r['@type']=='getCountries') return countryData;
      if(r['@type']=='setAuthenticationPhoneNumber') codeState(td,r['phone_number'] as String);
      return null;
    };
    final service=TelegramService(directory,vault,transport:td,applicationApiId:12345,applicationApiHash:'a'*32);
    addTearDown(service.shutdown);
    await tester.runAsync(()=>service.start());td.auth('authorizationStateWaitPhoneNumber');
    await tester.pumpWidget(MaterialApp(home:Scaffold(body:SingleChildScrollView(padding:const EdgeInsets.all(16),child:ListenableBuilder(
      listenable:service,builder:(_,_)=>AuthForm(telegram:service),
    )))));
    Future<void> choose(String query,String key) async {
      await tester.tap(find.byKey(const ValueKey('login-country')));await tester.pumpAndSettle();
      await tester.enterText(find.byKey(const ValueKey('country-search')),query);await tester.pump();
      await tester.tap(find.byKey(ValueKey(key)));await tester.pumpAndSettle();
    }
    await choose('880','country-BD-880');
    await tester.enterText(find.byKey(const ValueKey('login-phone')),'1712345678');
    await tester.tap(find.text('Continue'));await tester.pumpAndSettle();
    expect(find.text('Code sent to +8801712345678'),findsOneWidget);
    await tester.enterText(find.byType(TextField),'stale-code');
    await tester.tap(find.text('Change number'));await tester.pumpAndSettle();
    expect(tester.widget<TextField>(find.byKey(const ValueKey('login-phone'))).controller!.text,'1712345678');
    await tester.enterText(find.byKey(const ValueKey('login-phone')),'1812345678');
    await tester.tap(find.text('Cancel number change'));await tester.pumpAndSettle();
    expect(td.requests.where((r)=>r['@type']=='setAuthenticationPhoneNumber'),hasLength(1));
    await tester.tap(find.text('Change number'));await tester.pumpAndSettle();
    await choose('Japan','country-JP-81');
    await tester.enterText(find.byKey(const ValueKey('login-phone')),'9012345678');
    await tester.tap(find.text('Send new code'));await tester.pumpAndSettle();
    expect(find.text('Code sent to +819012345678'),findsOneWidget);
    expect(td.requests.where((r)=>r['@type']=='setAuthenticationPhoneNumber').last['phone_number'],'+819012345678');
    expect(tester.widget<TextField>(find.byType(TextField)).controller!.text,isEmpty);
    expect(td.requests.where((r)=>r['@type']=='checkAuthenticationCode'),isEmpty);
    expect(vault.data.keys.toSet(),{'apiId','apiHash','databaseKey'});
    expect(tester.takeException(),isNull);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('country picker fits a small landscape screen with keyboard and large text', (tester) async {
    tester.view.devicePixelRatio=1;tester.view.physicalSize=const Size(844,390);
    addTearDown(tester.view.resetPhysicalSize);addTearDown(tester.view.resetDevicePixelRatio);
    final number=TextEditingController();addTearDown(number.dispose);
    await tester.pumpWidget(MaterialApp(builder:(context,child)=>MediaQuery(
      data:MediaQuery.of(context).copyWith(textScaler:TextScaler.linear(1.6),viewInsets:const EdgeInsets.only(bottom:160)),child:child!,
    ),home:Scaffold(body:SingleChildScrollView(padding:const EdgeInsets.all(16),child:PhoneNumberInput(
      controller:number,country:null,onCountryChanged:(_){},loadCountries:() async=>PhoneCountry.fromResponse(countryData),enabled:true,onSubmitted:(){},
    )))));
    await tester.tap(find.byKey(const ValueKey('login-country')));await tester.pumpAndSettle();
    await tester.enterText(find.byKey(const ValueKey('country-search')),'Italy');await tester.pump();
    expect(find.byKey(const ValueKey('country-IT-39')),findsOneWidget);
    expect(tester.takeException(),isNull);
    await tester.tap(find.byTooltip('Close country picker'));await tester.pumpAndSettle();
    await tester.pumpWidget(const SizedBox());
  });
}
