import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'controller.dart';
import 'document.dart';

class SyncSettings extends StatefulWidget {
  const SyncSettings({super.key,required this.controller});
  final SyncController controller;
  @override
  State<SyncSettings> createState() => _SyncSettingsState();
}
class _SyncSettingsState extends State<SyncSettings> {
  late final _url=TextEditingController(text:widget.controller.url);
  final _key=TextEditingController();
  bool _busy=false;
  String? _error;
  Future<void> _connect() async {
    setState(() {_busy=true;_error=null;});
    try { await widget.controller.connect(_url.text,_key.text);_key.clear(); }
    catch (_) { if(mounted) setState(() => _error='Could not connect. Check the service URL and private sync key.'); }
    finally {if(mounted) setState(() => _busy=false);}
  }
  @override
  void dispose() {_url.dispose();_key.dispose();super.dispose();}
  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable:widget.controller,
    builder:(context,_) {
      final sync=widget.controller;
      return Card(
        margin:const EdgeInsets.symmetric(vertical:12),
        child:Padding(
          padding:const EdgeInsets.all(20),
          child:Column(crossAxisAlignment:CrossAxisAlignment.start,children:[
            const Text('Multi-device sync',style:TextStyle(fontSize:18,fontWeight:FontWeight.w700)),
            const SizedBox(height:8),
            const Text('Sync favorites, playlists, recent music, listening stats, channel selections and shared preferences. Music, volume, playback and Telegram sign-in stay on each device.'),
            const SizedBox(height:12),
            Text(sync.status),
            if(sync.error ?? _error case final String error) Padding(padding:const EdgeInsets.only(top:8),child:Text(error,style:TextStyle(color:Theme.of(context).colorScheme.error))),
            if(sync.syncing) const LinearProgressIndicator(),
            if(!sync.connected) ...[
              const SizedBox(height:12),
              TextField(controller:_url,autocorrect:false,keyboardType:TextInputType.url,decoration:const InputDecoration(labelText:'Sync service URL',hintText:'https://auralis-sync.example.workers.dev')),
              const SizedBox(height:12),
              TextField(controller:_key,obscureText:true,autocorrect:false,enableSuggestions:false,decoration:const InputDecoration(labelText:'Private sync key',helperText:'Use the same URL and key on all your devices.')),
              const SizedBox(height:8),
              const Text('Connect merges this device’s library with your private sync space. Deploy the Auralis sync service once before connecting.'),
            ],
            const SizedBox(height:12),
            Wrap(spacing:8,runSpacing:8,children:[
              if(!sync.connected) FilledButton(onPressed:_busy?null:_connect,child:Text(_busy?'Connecting…':'Connect and merge')),
              if(!sync.connected) TextButton(onPressed:_busy?null:() async {
                final value=newSyncKey();_key.text=value;
                await Clipboard.setData(ClipboardData(text:value));
                if(context.mounted) ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content:Text('New sync key copied. Use it when deploying your service.')));
              },child:const Text('Create key')),
              if(!sync.connected) TextButton(onPressed:_busy?null:() async {
                try {
                  final text=await Clipboard.getData(Clipboard.kTextPlain);
                  final data=jsonDecode(text?.text ?? '') as Map;
                  if(data['url'] is! String || data['key'] is! String) throw const FormatException('Invalid connection details');
                  _url.text=data['url'] as String;_key.text=data['key'] as String;
                } catch (_) {if(mounted) setState(() => _error='Copy connection details from your other device first.');}
              },child:const Text('Paste connection')),
              if(sync.connected) TextButton(onPressed:() async {
                try {
                  final data=await sync.connectionDetails();
                  await Clipboard.setData(ClipboardData(text:data));
                  if(context.mounted) ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content:Text('Connection details copied. Keep them private.')));
                } catch (_) {if(mounted) setState(() => _error='Could not copy connection details. Please retry.');}
              },child:const Text('Copy connection')),
              if(sync.connected) FilledButton.tonal(onPressed:sync.syncing?null:sync.sync,child:const Text('Sync now')),
              if(sync.connected) TextButton(onPressed:() async {
                final yes=await showDialog<bool>(context:context,builder:(c) => AlertDialog(title:const Text('Disconnect sync?'),content:const Text('Your local library and cloud data are kept. Changes will stop syncing on this device.'),actions:[TextButton(onPressed:()=>Navigator.pop(c,false),child:const Text('Cancel')),FilledButton(onPressed:()=>Navigator.pop(c,true),child:const Text('Disconnect'))]));
                if(yes==true) {try {await sync.disconnect();} catch (_) {if(mounted) setState(() => _error='Could not disconnect. Please retry.');}}
              },child:const Text('Disconnect')),
            ]),
          ]),
        ),
      );
    },
  );
}
