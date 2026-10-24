import {DatabaseSync} from 'node:sqlite';
export function fakeTurso() {
  const db=new DatabaseSync(':memory:');
  const fixture={db,calls:0,fail:null,beforeBatch:null};
  function execute(stmt) {
    if(fixture.fail?.(stmt.sql)) throw new Error('injected database failure');
    const query=db.prepare(stmt.sql),args=(stmt.args ?? []).map(a=>a.type==='integer'?Number(a.value):a.value);
    const cols=query.columns().map(c=>({name:c.name}));
    if(!cols.length) {query.run(...args);return {cols:[],rows:[]};}
    const rows=query.all(...args).map(row=>cols.map(col=>{
      const value=row[col.name];return {type:typeof value==='number'?'integer':value===null?'null':'text',...(value===null?{}:{value:String(value)})};
    }));
    return {cols,rows};
  }
  fixture.send=async(url,options)=>{
    fixture.calls++;
    if(url!=='https://auralis-test.turso.io/v2/pipeline' || options.headers.Authorization!=='Bearer database-token') return Response.json({error:'Unauthorized'},{status:401});
    const input=JSON.parse(options.body),results=[];
    for(const request of input.requests) {
      if(request.type==='close') {results.push({type:'ok',response:{type:'close'}});continue;}
      if(request.type==='execute') {
        try {results.push({type:'ok',response:{type:'execute',result:execute(request.stmt)}});}
        catch(error) {results.push({type:'error',error:{message:error.message}});}
        continue;
      }
      if(request.type!=='batch') throw new Error('unsupported protocol request');
      fixture.beforeBatch?.(request.batch);
      const step_results=[],step_errors=[];
      const condition=c=>!c || (c.type==='ok'?step_results[c.step]!=null:c.type==='not'?!condition(c.cond):false);
      for(const step of request.batch.steps) {
        let result=null,error=null;
        if(condition(step.condition)) {try {result=execute(step.stmt);} catch(e) {error={message:e.message};}}
        step_results.push(result);step_errors.push(error);
      }
      results.push({type:'ok',response:{type:'batch',result:{step_results,step_errors}}});
    }
    return Response.json({results});
  };
  return fixture;
}
