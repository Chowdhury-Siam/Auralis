import 'package:flutter/material.dart';

class PhoneCountry {
  const PhoneCountry(this.iso,this.name,this.englishName,this.callingCode);
  final String iso,name,englishName,callingCode;
  String get label=>'$name (+$callingCode)';
  bool matches(String query)=>'$name $englishName $iso +$callingCode'.toLowerCase().contains(query.trim().toLowerCase());
  static List<PhoneCountry> fromResponse(Map response) {
    final raw=response['countries'];
    if(raw is! List) throw const FormatException('Country list is unavailable.');
    final countries=<String,PhoneCountry>{};
    for(final country in raw) {
      if(country is! Map || country['is_hidden']==true || country['calling_codes'] is! List) continue;
      final iso=country['country_code'],name=country['name'],english=country['english_name'];
      if(iso is! String || name is! String || english is! String || !RegExp(r'^[A-Z]{2}$').hasMatch(iso)) continue;
      for(final code in country['calling_codes'] as List) {
        if(code is String && RegExp(r'^[1-9][0-9]{0,5}$').hasMatch(code)) countries['$iso:$code']=PhoneCountry(iso,name.isEmpty?english:name,english,code);
      }
    }
    if(countries.isEmpty) throw const FormatException('Country list is unavailable.');
    return countries.values.toList()..sort((a,b)=>a.englishName.compareTo(b.englishName));
  }
}

String internationalLoginNumber(String input,{PhoneCountry? country}) {
  var number=input.trim().replaceAll(RegExp(r'[\s().-]'),'');
  if(number.startsWith('00')) number='+${number.substring(2)}';
  if(!number.startsWith('+')) {
    if(country==null) throw const FormatException('Choose a country code or enter a full number beginning with +.');
    number='+${country.callingCode}$number';
  }
  if(!RegExp(r'^\+[1-9][0-9]{4,14}$').hasMatch(number)) throw const FormatException('Enter a valid international phone number.');
  return number;
}

class PhoneNumberInput extends StatelessWidget {
  const PhoneNumberInput({super.key,required this.controller,required this.country,
    required this.onCountryChanged,required this.loadCountries,required this.enabled,required this.onSubmitted});
  final TextEditingController controller;
  final PhoneCountry? country;
  final ValueChanged<PhoneCountry> onCountryChanged;
  final Future<List<PhoneCountry>> Function() loadCountries;
  final bool enabled;
  final VoidCallback onSubmitted;
  @override
  Widget build(BuildContext context)=>Column(crossAxisAlignment:CrossAxisAlignment.stretch,children:[
    OutlinedButton(
      key:const ValueKey('login-country'),
      onPressed:!enabled?null:() async {
        FocusScope.of(context).unfocus();
        final choice=await showDialog<PhoneCountry>(context:context,builder:(_)=>_CountryPicker(load:loadCountries,selected:country));
        if(context.mounted && choice!=null) onCountryChanged(choice);
      },
      child:Padding(padding:const EdgeInsets.symmetric(vertical:12),child:Row(children:[
        const Icon(Icons.public_rounded,size:20),const SizedBox(width:10),
        Expanded(child:Text(country?.label ?? 'Choose country code',maxLines:2,overflow:TextOverflow.ellipsis)),
        const Icon(Icons.expand_more_rounded),
      ])),
    ),
    const SizedBox(height:12),
    TextField(
      key:const ValueKey('login-phone'),controller:controller,enabled:enabled,
      keyboardType:TextInputType.phone,autofillHints:const [AutofillHints.telephoneNumber],
      autocorrect:false,enableSuggestions:false,textInputAction:TextInputAction.done,
      onSubmitted:enabled?(_)=>onSubmitted():null,
      decoration:InputDecoration(labelText:'Phone number',
        helperText:country==null?'Choose a country, or paste a full +number.':'Enter the number after +${country!.callingCode}, or paste a full +number.',helperMaxLines:3),
    ),
  ]);
}

class _CountryPicker extends StatefulWidget {
  const _CountryPicker({required this.load,this.selected});
  final Future<List<PhoneCountry>> Function() load;
  final PhoneCountry? selected;
  @override
  State<_CountryPicker> createState()=>_CountryPickerState();
}
class _CountryPickerState extends State<_CountryPicker> {
  final _search=TextEditingController();
  List<PhoneCountry>? _countries;
  bool _failed=false;
  @override
  void initState(){super.initState();_load();}
  Future<void> _load() async {
    setState(() {_countries=null;_failed=false;});
    try {final result=await widget.load();if(mounted) setState(()=>_countries=result);}
    catch (_) {if(mounted) setState(()=>_failed=true);}
  }
  @override
  void dispose(){_search.dispose();super.dispose();}
  @override
  Widget build(BuildContext context) {
    final visible=_countries?.where((c)=>c.matches(_search.text)).toList();
    return Dialog(child:ConstrainedBox(constraints:const BoxConstraints(maxWidth:460,maxHeight:520),child:Padding(
      padding:const EdgeInsets.all(12),child:CustomScrollView(shrinkWrap:true,slivers:[
        SliverToBoxAdapter(child:TextField(
          key:const ValueKey('country-search'),controller:_search,autocorrect:false,
          onChanged:(_)=>setState((){}),
          decoration:InputDecoration(labelText:'Search country or code',prefixIcon:const Icon(Icons.search_rounded),
            suffixIcon:IconButton(tooltip:'Close country picker',onPressed:()=>Navigator.pop(context),icon:const Icon(Icons.close_rounded))),
        )),
        if(_failed) SliverToBoxAdapter(child:Padding(padding:const EdgeInsets.all(16),child:Column(children:[
          const Text('Could not load countries. Retry, or enter a full +number on the sign-in page.'),
          TextButton(onPressed:_load,child:const Text('Retry')),
        ])))
        else if(visible==null) const SliverToBoxAdapter(child:Padding(padding:EdgeInsets.all(24),child:Center(child:CircularProgressIndicator())))
        else if(visible.isEmpty) const SliverToBoxAdapter(child:Padding(padding:EdgeInsets.all(24),child:Text('No matching country.')))
        else SliverList.builder(itemCount:visible.length,itemBuilder:(context,index) {
          final country=visible[index];
          return ListTile(
            key:ValueKey('country-${country.iso}-${country.callingCode}'),
            title:Text(country.name,maxLines:2,overflow:TextOverflow.ellipsis),
            subtitle:Text('${country.iso} · +${country.callingCode}'),
            selected:widget.selected?.iso==country.iso && widget.selected?.callingCode==country.callingCode,
            onTap:()=>Navigator.pop(context,country),
          );
        }),
      ]),
    )));
  }
}
