import 'dart:convert';
import 'package:flutter/material.dart';
import '../release_notes.dart';
import 'controller.dart';
import 'deployment.dart';
import 'document.dart';

class SyncDeploymentPage extends StatefulWidget {
  const SyncDeploymentPage({super.key,required this.sync});
  final SyncController sync;
  @override
  State<SyncDeploymentPage> createState()=>_SyncDeploymentPageState();
}
class _SyncDeploymentPageState extends State<SyncDeploymentPage> {
  final _fields={for(final key in ['worker','account','cloudflareToken','database','databaseToken','key']) key:TextEditingController()};
  final _deployment=SyncDeployment();
  bool _busy=true,_loaded=false;
  String? _error,_savedVersion;
  String _status='Loading saved setup…';
  @override
  void initState() {super.initState();_load();}
  Future<void> _load() async {
    setState(()=>_busy=true);
    try {
      final profile=await widget.sync.deploymentVault!.read();
      if(!mounted) return;
      for(final entry in _fields.entries) {entry.value.text=profile[entry.key] is String?profile[entry.key] as String:'';}
      if(_fields['worker']!.text.isEmpty) _fields['worker']!.text='auralis-sync';
      if(_fields['key']!.text.isEmpty) {
        if(widget.sync.connected) {
          final connection=jsonDecode(await widget.sync.connectionDetails()) as Map;
          if(!mounted) return;
          _fields['key']!.text=connection['key'] as String;
        } else {_fields['key']!.text=newSyncKey();}
      }
      _savedVersion=profile['version'] as String?;
      setState(() {_loaded=true;_error=null;_status=_savedVersion==null?'Ready to set up your private sync service.':'Saved deployment: $_savedVersion · app service: $currentReleaseVersion';});
    } catch (_) {if(mounted) setState(()=>_error='Could not unlock the saved deployment. Restart Auralis or retry.');}
    finally {if(mounted) setState(()=>_busy=false);}
  }
  Future<void> _deploy() async {
    final c=SyncDeploymentConfig(worker:_fields['worker']!.text,account:_fields['account']!.text,
      cloudflareToken:_fields['cloudflareToken']!.text,database:_fields['database']!.text,
      databaseToken:_fields['databaseToken']!.text,key:_fields['key']!.text);
    setState(() {_busy=true;_error=null;});
    try {
      c.validate();
      // Save before uploading so a completed upload is recoverable after a
      // timeout or process exit. The pair key must never rotate on retry.
      await widget.sync.deploymentVault!.write({...c.toJson(),'version':_savedVersion});
      final url=await _deployment.deploy(c,(status) {if(mounted) setState(()=>_status=status);});
      await widget.sync.deploymentVault!.write({...c.toJson(),'url':url,'version':currentReleaseVersion});
      _savedVersion=currentReleaseVersion;
      if(!mounted) return;
      setState(()=>_status='Deployed. Connecting and merging your library…');
      await widget.sync.connect(url,c.key);
      if(mounted) setState(()=>_status=widget.sync.error==null?'Deployed and connected. Copy connection details in Settings to pair your other devices.':'Deployed. ${widget.sync.status}');
    } on FormatException catch(e) {if(mounted) setState(()=>_error=e.message);}
    catch (_) {if(mounted) setState(()=>_error='Setup did not finish. Check your connection, Cloudflare permissions and Turso token, then retry. Saved values and cloud data are kept.');}
    finally {if(mounted) setState(()=>_busy=false);}
  }
  Widget _field(String key,String label,{bool secret=false,String? hint}) => Padding(
    padding:const EdgeInsets.only(bottom:12),
    child:TextField(key:ValueKey('deploy-$key'),controller:_fields[key],enabled:!_busy,obscureText:secret,autocorrect:false,enableSuggestions:false,
      onTapOutside:(_)=>FocusManager.instance.primaryFocus?.unfocus(),
      decoration:InputDecoration(labelText:label,hintText:hint)),
  );
  @override
  void dispose() {_deployment.close();for(final field in _fields.values) {field.dispose();}super.dispose();}
  @override
  Widget build(BuildContext context)=>PopScope<Object?>(
    canPop:!_busy,
    child:Scaffold(
      appBar:AppBar(title:const Text('Set up cloud sync'),automaticallyImplyLeading:!_busy),
      body:SafeArea(child:Center(child:ConstrainedBox(constraints:const BoxConstraints(maxWidth:660),child:ListView(
        padding:const EdgeInsets.all(20),children:[
          const Text('Cloudflare + Turso',style:TextStyle(fontSize:22,fontWeight:FontWeight.w700)),
          const SizedBox(height:8),
          const Text('Use a dedicated Turso database and its read/write token. Auralis prepares the database tables and deploys your private Cloudflare Worker. Deployment credentials stay protected on this device.'),
          const SizedBox(height:16),
          _field('worker','Worker name',hint:'auralis-sync'),
          _field('account','Cloudflare Account ID'),
          _field('cloudflareToken','Cloudflare API token',secret:true),
          _field('database','Turso database URL',hint:'libsql://auralis-yourname.turso.io'),
          _field('databaseToken','Turso database token',secret:true),
          _field('key','Private sync key',secret:true),
          const Text('Keep the existing sync key when redeploying. On another device, use Copy connection / Paste connection instead of deploying again.'),
          const SizedBox(height:16),
          if(_busy) const LinearProgressIndicator(),
          const SizedBox(height:8),Text(_status),
          if(_error!=null) Padding(padding:const EdgeInsets.symmetric(vertical:12),child:Text(_error!,style:TextStyle(color:Theme.of(context).colorScheme.error))),
          const SizedBox(height:12),
          Wrap(spacing:8,runSpacing:8,children:[
            FilledButton.icon(onPressed:_busy || !_loaded?null:_deploy,icon:const Icon(Icons.cloud_upload_outlined),label:Text(_savedVersion==null?'Deploy and connect':'Redeploy and connect')),
            if(!_loaded) TextButton(onPressed:_busy?null:_load,child:const Text('Retry loading')),
          ]),
        ],
      )))),
    ),
  );
}
