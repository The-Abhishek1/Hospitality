"use server";
import { redirect } from "next/navigation";
import { createClient } from "@/lib/supabase/server";

const to = (pid: string, error?: string): never => redirect(`/p/${pid}/channels${error ? `?error=${encodeURIComponent(error)}` : ""}`);

export async function connectChannel(fd: FormData) {
  const pid = String(fd.get("pid"));
  const supabase = await createClient();
  const { error } = await supabase.rpc("connect_channel", { p_property: pid, p_provider: String(fd.get("provider")) });
  to(pid, error?.message);
}

export async function mapRoom(fd: FormData) {
  const pid = String(fd.get("pid"));
  const supabase = await createClient();
  const { error } = await supabase.rpc("map_channel_room", {
    p_connection: String(fd.get("connection")), p_type: String(fd.get("type")), p_external_room_id: String(fd.get("external")).trim(),
  });
  to(pid, error?.message);
}

export async function resync(fd: FormData) {
  const pid = String(fd.get("pid"));
  const supabase = await createClient();
  const { error } = await supabase.rpc("request_channel_resync", { p_connection: String(fd.get("connection")) });
  to(pid, error?.message);
}

export async function prepareChannel(fd: FormData) {
  const pid = String(fd.get("pid"));
  const supabase = await createClient();
  const { error } = await supabase.rpc("prepare_channel", {
    p_property: pid, p_provider: String(fd.get("provider")),
    p_external_property_id: String(fd.get("hotel")).trim(),
    p_credentials_ref: String(fd.get("reference") || "").trim() || null,
  });
  to(pid, error?.message);
}

export async function mapRate(fd: FormData) {
  const pid=String(fd.get('pid')),db=await createClient();
  const {error}=await db.rpc('map_channel_rate',{p_connection:String(fd.get('connection')),p_rate:String(fd.get('rate')),p_external:String(fd.get('external')).trim()});
  to(pid,error?.message);
}
export async function saveRates(fd: FormData) {
  const pid=String(fd.get('pid')),db=await createClient();
  const flag=(key:string)=>fd.get(key)==='true'?true:fd.get(key)==='false'?false:null;
  const integer=(key:string)=>String(fd.get(key)||'').trim()===''?null:Number(fd.get(key));
  const {error}=await db.rpc('set_channel_rates',{
    p_connection:String(fd.get('connection')),p_type:String(fd.get('type')),p_rate:String(fd.get('rate')),
    p_from:String(fd.get('from')),p_to:String(fd.get('to')),p_amount:String(fd.get('amount')),
    p_closed:flag('closed'),p_cta:flag('cta'),p_ctd:flag('ctd'),p_min_los:integer('min'),p_max_los:integer('max'),
  });
  to(pid,error?.message);
}
