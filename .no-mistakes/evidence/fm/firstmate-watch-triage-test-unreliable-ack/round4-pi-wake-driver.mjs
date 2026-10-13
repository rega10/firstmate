import {createServer} from 'node:http';
import {mkdirSync,writeFileSync,readFileSync,existsSync,copyFileSync} from 'node:fs';
import {pathToFileURL} from 'node:url';
const root=process.cwd(), lab=`${root}/.test-phase-temp/pi-wake-lab`, agentDir=`${lab}/agent`, evidence=process.env.EVIDENCE_DIR;
mkdirSync(agentDir,{recursive:true});
Object.assign(process.env,{FM_HOME:lab,FM_ROOT_OVERRIDE:`${root}/.test-phase-temp/pi-wake-code`,FM_VALIDATION_LAB:lab,FM_VALIDATION_CODE:root,PI_CODING_AGENT_DIR:agentDir,PI_OFFLINE:'1',FM_POLL:'1',FM_SIGNAL_GRACE:'0',FM_HEARTBEAT:'999999',FM_CHECK_INTERVAL:'999999',FM_SECONDMATE_LIVENESS_SECS:'99999999',FM_WATCH_EXTENSION_LOG:'1'});
const errors=[], events=[]; let count=0, firstStarted=false;
const server=createServer(async(req,res)=>{
 for await(const chunk of req){}
 const requestIndex=++count;
 res.writeHead(200,{'Content-Type':'text/event-stream'});
 const chunk={id:'local',object:'chat.completion.chunk',created:1,model:'local',choices:[{index:0,delta:{role:'assistant',content:'Local endpoint response.'},finish_reason:null}]};
 res.write(`data: ${JSON.stringify(chunk)}\n\n`);
 if(requestIndex===1){firstStarted=true;return;}
 res.write(`data: ${JSON.stringify({...chunk,choices:[{index:0,delta:{},finish_reason:'stop'}]})}\n\n`);
 res.end('data: [DONE]\n\n');
});
await new Promise(r=>server.listen(0,'127.0.0.1',r));
writeFileSync(`${agentDir}/models.json`,JSON.stringify({providers:{'isolated-endpoint':{baseUrl:`http://127.0.0.1:${server.address().port}/v1`,api:'openai-completions',apiKey:'local-fixture',models:[{id:'local',contextWindow:128000,maxTokens:1024}]}}}));
writeFileSync(`${agentDir}/settings.json`,JSON.stringify({defaultProvider:'isolated-endpoint',defaultModel:'local'}));
writeFileSync(`${lab}/state/.lock`,`${process.pid}\n`);
const sdk=await import(pathToFileURL(`${root}/.test-phase-temp/pi-runtime/node_modules/@earendil-works/pi-coding-agent/dist/index.js`));
const serviceSdk=await import(pathToFileURL(`${root}/.test-phase-temp/pi-runtime/node_modules/@earendil-works/pi-coding-agent/dist/core/agent-session-services.js`));
const runtimeModel=await sdk.ModelRuntime.create({authPath:`${agentDir}/auth.json`,modelsPath:`${agentDir}/models.json`});
const handoffPath=`${lab}/state/extensions/pi-primary-watch/session-replacement-actionable.json`;
let handoff, queuedWake;
const factory=async options=>{
 if(options.sessionStartEvent?.reason==='new'){
   if(!existsSync(handoffPath))throw Error('unconsumed wake handoff missing');
   handoff=JSON.parse(readFileSync(handoffPath,'utf8'));
   copyFileSync(handoffPath,`${evidence}/round4-pi-wake-handoff.json`);
   console.log('REPLACEMENT_HANDOFF',JSON.stringify(handoff));
   if(handoff.pending.length!==1 || handoff.pending[0].message!==`signal: ${lab}/state/isolated.status` || handoff.pending[0].delivered)throw Error('custom event consumed or changed the pending wake');
 }
 const services=await serviceSdk.createAgentSessionServices({cwd:lab,agentDir,modelRuntime:runtimeModel,resourceLoaderOptions:{noExtensions:true,noSkills:true,noPromptTemplates:true,noThemes:true,noContextFiles:true,additionalExtensionPaths:[`${root}/.pi/extensions/fm-primary-pi-watch.ts`],extensionFactories:[{name:'observer',factory:pi=>{pi.on('before_agent_start',event=>{events.push(event);console.log('PI_EVENT',JSON.stringify({messageType:event.messageType,prompt:event.prompt,message:event.message}));});}}]}});
 const created=await serviceSdk.createAgentSessionFromServices({services,sessionManager:options.sessionManager,sessionStartEvent:options.sessionStartEvent,tools:[]});
 created.session.extensionRunner.onError(error=>{errors.push(error);console.log('EXTENSION_ERROR',JSON.stringify(error));});
 await created.session.bindExtensions({mode:'rpc',abortHandler:()=>{void created.session.abort();}});
 return {...created,services,diagnostics:services.diagnostics};
};
const waitFor=async(predicate,label)=>{for(let i=0;i<400;i++){if(predicate())return;await new Promise(r=>setTimeout(r,50));}throw Error(`timeout: ${label}`);};
const runtime=await sdk.createAgentSessionRuntime(factory,{cwd:lab,agentDir,sessionManager:sdk.SessionManager.create(lab,`${lab}/sessions`)});
try{
 const pendingRun=runtime.session.prompt('Hold this response while the isolated watcher queues a wake.');
 await waitFor(()=>firstStarted,'first provider stream');
 writeFileSync(`${lab}/state/isolated.status`,'done: ISOLATED_WAKE_SENTINEL\n');
 await waitFor(()=>runtime.session.getFollowUpMessages().length===1,'real watcher follow-up');
 queuedWake=runtime.session.getFollowUpMessages()[0];
 console.log('ACTUAL_QUEUED_WAKE',queuedWake);
 if(!queuedWake.includes(`signal: ${lab}/state/isolated.status`))throw Error('a watcher failure replaced the intended wake');
 console.log('QUEUED_WAKE',queuedWake);
 await runtime.session.abort(); await pendingRun;
 runtime.session.clearQueue();
 for(const content of [queuedWake,[{type:'text',text:queuedWake}]]){
   await runtime.session.sendCustomMessage({customType:'extension-note',content,display:false},{triggerTurn:true});
 }
 if(!events.some(event=>event.messageType==='custom'))throw Error('Pi did not emit custom events');
 await runtime.newSession();
 await waitFor(()=>!existsSync(handoffPath),'replayed user wake consumes its handoff');
 if(errors.length)throw Error('extension errors');
 console.log('VERIFIED real watcher wake survives identical custom events, rides session replacement, and clears after real user replay.');
}finally{await runtime.dispose();server.closeAllConnections();server.close();}
