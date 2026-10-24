// No SDK dependency: use Turso's authenticated SQL-over-HTTP protocol.
export const schema = [
  'CREATE TABLE IF NOT EXISTS auralis_records (key TEXT PRIMARY KEY, value TEXT NOT NULL, revision INTEGER NOT NULL)',
  'CREATE INDEX IF NOT EXISTS auralis_revisions ON auralis_records(revision)',
  'CREATE TABLE IF NOT EXISTS auralis_meta (id INTEGER PRIMARY KEY CHECK(id=1), revision INTEGER NOT NULL CHECK(revision>=0))',
  'INSERT OR IGNORE INTO auralis_meta VALUES(1,0)',
];
export function databaseUrl(value) {
  const normalized=value.replace(/^(libsql|turso):\/\//,'https://');
  if(!/^https:\/\/[a-z0-9-]+\.turso\.io\/?$/.test(normalized)) throw new Error('Use your Turso database URL.');
  const url=new URL(normalized);
  if(url.protocol!=='https:' || !/^[a-z0-9-]+\.turso\.io$/.test(url.hostname) || url.username || url.password || url.port || !['','/'].includes(url.pathname) || url.search || url.hash) throw new Error('Use your Turso database URL.');
  return url.origin;
}
export const statement=(sql,...args)=>({sql,args:args.map(value=>typeof value==='number'?{type:'integer',value:String(value)}:{type:'text',value})});
export class TursoStore {
  constructor(env,send=fetch) {this.url=databaseUrl(env.TURSO_DATABASE_URL);this.token=env.TURSO_AUTH_TOKEN;this.send=send;}
  async batch(statements) {
    const steps=[{stmt:statement('BEGIN IMMEDIATE')}];
    for(const stmt of statements) steps.push({condition:{type:'ok',step:steps.length-1},stmt});
    const commit=steps.length;steps.push({condition:{type:'ok',step:commit-1},stmt:statement('COMMIT')});
    steps.push({condition:{type:'not',cond:{type:'ok',step:commit}},stmt:statement('ROLLBACK')});
    const response=await this.send(`${this.url}/v2/pipeline`,{method:'POST',redirect:'error',signal:AbortSignal.timeout(12000),headers:{Authorization:`Bearer ${this.token}`,'Content-Type':'application/json'},body:JSON.stringify({requests:[{type:'batch',batch:{steps}},{type:'close'}]})});
    if(!response.ok) throw new Error('Turso request failed');
    const data=await response.json(),result=data.results?.[0]?.response?.result;
    if(!result || data.results.some(r=>r.type==='error')) throw new Error('Turso response is invalid');
    if(result.step_errors?.some(Boolean)) {
      const error=new Error('Turso transaction failed');
      error.conflict=result.step_errors.some(e=>e?.message?.includes('revision>=0'));
      throw error;
    }
    if(!result.step_results?.[commit]) throw new Error('Turso transaction did not commit');
    return result.step_results.slice(1,commit).map(r=>{
      if(!r || !Array.isArray(r.rows) || !Array.isArray(r.cols)) throw new Error('Turso statement result is invalid');
      return r.rows.map(row=>Object.fromEntries(r.cols.map((col,i)=>[col.name,row[i].type==='integer'?Number(row[i].value):row[i].value])));
    });
  }
  async initialize() {await this.batch(schema.map(sql=>statement(sql)));}
  async sync(data,merge) {
    for(let attempt=0;attempt<3;attempt++) {
      const entries=Object.entries(data.ops);
      const queries=[statement('SELECT revision FROM auralis_meta WHERE id=1'),statement('SELECT count(*) AS n FROM auralis_records')];
      if(entries.length) queries.push(statement(`SELECT key,value FROM auralis_records WHERE key IN (${entries.map(()=>'?').join(',')})`,...entries.map(([key])=>key)));
      const [meta,count,stored=[]]=await this.batch(queries);
      let revision=meta[0].revision;const original=revision;
      if(data.cursor>revision) throw new Error('Sync history changed; reconnect this device');
      const old=new Map(stored.map(row=>[row.key,JSON.parse(row.value)])),writes=[];
      let total=count[0].n;
      for(const [key,next] of entries) {
        const previous=old.get(key) ?? null,result=merge(key,previous,next);
        if(JSON.stringify(previous)===JSON.stringify(result)) continue;
        if(!previous && ++total>50000) throw new Error('Sync space is full');
        if(!Number.isSafeInteger(++revision)) throw new Error('Sync revision limit reached');
        writes.push(statement('INSERT INTO auralis_records VALUES(?,?,?) ON CONFLICT(key) DO UPDATE SET value=excluded.value,revision=excluded.revision',key,JSON.stringify(result),revision));
      }
      if(writes.length) {
        try {
          await this.batch([statement('UPDATE auralis_meta SET revision=CASE WHEN revision=? THEN ? ELSE -1 END WHERE id=1',original,revision),...writes]);
        } catch(error) {if(error.conflict && attempt<2) continue;throw error;}
      }
      const [current,rows]=await this.batch([statement('SELECT revision FROM auralis_meta WHERE id=1'),statement('SELECT key,value,revision FROM auralis_records WHERE revision>? ORDER BY revision LIMIT 200',data.cursor)]);
      const cursor=rows.length?rows.at(-1).revision:current[0].revision;
      return {changed:writes.length>0,output:{cursor,more:cursor<current[0].revision,records:Object.fromEntries(rows.map(row=>[row.key,JSON.parse(row.value)]))}};
    }
    throw new Error('Turso changed concurrently; retry sync');
  }
}
