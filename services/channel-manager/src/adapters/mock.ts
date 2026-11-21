import type { SupabaseClient } from "@supabase/supabase-js";
import type { AvailabilityPush, ChannelAdapter, ConnectionCtx, NormalizedEvent } from "../adapter.js";

// Test double: the "OTA" is a pair of tables in our own database (mock_ota_availability / mock_ota_outbox).
export class MockAdapter implements ChannelAdapter {
  readonly provider = "mock";
  constructor(private db: SupabaseClient) {}

  async pushAvailability(ctx: ConnectionCtx, push: AvailabilityPush): Promise<void> {
    for (const d of push.days) {
      const { error } = await this.db.rpc("mock_provider_push", {
        p_connection: ctx.connectionId, p_room: push.externalRoomId, p_day: d.day, p_available: d.available,
      });
      if (error) throw new Error(`mock push failed: ${error.message}`);
    }
  }

  async fetchEvents(ctx: ConnectionCtx): Promise<NormalizedEvent[]> {
    const { data, error } = await this.db.from("mock_ota_outbox").select("id,payload").eq("connection_id",ctx.connectionId).order("created_at").limit(50);
    if (error) throw new Error("mock poll failed");
    return (data ?? []).map(row=>({externalEventId:row.id,payload:row.payload as Record<string,unknown>}));
  }

  async acknowledgeEvent(ctx: ConnectionCtx, event: NormalizedEvent): Promise<void> {
    const {error} = await this.db.from("mock_ota_outbox").delete().eq("connection_id",ctx.connectionId).eq("id",event.externalEventId);
    if(error) throw new Error("mock acknowledgement failed");
  }

  async fetchRemoteAvailability(ctx: ConnectionCtx, room: string, from: string, to: string) {
    const { data, error } = await this.db.from("mock_ota_availability").select("day, available")
      .eq("connection_id", ctx.connectionId).eq("external_room_id", room).gte("day", from).lt("day", to);
    if (error) throw new Error(error.message);
    return (data ?? []) as { day: string; available: number }[];
  }
}
