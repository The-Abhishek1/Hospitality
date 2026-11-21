import type {SupabaseClient} from '@supabase/supabase-js';
import type {NormalizedEvent} from './adapter.js';
/** Null from ingest can mean duplicate OR inactive connection. Only a durable row permits acknowledgement/checkpoint. */
export async function persistChannelEvent(db:SupabaseClient,connectionId:string,event:NormalizedEvent):Promise<void> {
 const {data,error}=await db.rpc('ingest_channel_event',{p_connection:connectionId,p_external_id:event.externalEventId,p_payload:event.payload});
 if(error)throw new Error('Could not persist channel reservation event');
 if(data)return;
 const {data:existing,error:lookupError}=await db.from('channel_events').select('id').eq('connection_id',connectionId).eq('external_event_id',event.externalEventId).maybeSingle();
 if(lookupError||!existing)throw new Error('Channel event was not accepted; source retained');
}
