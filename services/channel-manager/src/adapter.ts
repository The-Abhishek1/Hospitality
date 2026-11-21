// Contract every OTA adapter implements. The core (database) never knows provider details: adapters translate
// to/from this neutral shape. A provider is only "supported" after partner access, certification and end-to-end tests.
export interface ConnectionCtx { connectionId: string; credentialsRef: string | null; externalPropertyId?: string | null; environment?: string }

export interface AvailabilityPush {
  externalRoomId: string;
  days: { day: string; available: number }[];     // night-by-night, YYYY-MM-DD
}

// Neutral inbound event; see process_channel_event() in the migration for the accepted shape.
export interface NormalizedEvent { externalEventId: string; payload: Record<string, unknown> }

export interface ChannelAdapter {
  readonly provider: string;
  pushAvailability(ctx: ConnectionCtx, push: AvailabilityPush): Promise<void>;
  /** Pull-based providers: return new events. Webhook providers can return [] and ingest from an edge function instead. */
  fetchEvents(ctx: ConnectionCtx): Promise<NormalizedEvent[]>;
  /** Called only after an event has been durably ingested, including duplicate deliveries. */
  acknowledgeEvent?(ctx: ConnectionCtx, event: NormalizedEvent): Promise<void>;
  /** Optional: read the provider's current availability so reconciliation can compare it with ours. */
  fetchRemoteAvailability?(ctx: ConnectionCtx, externalRoomId: string, from: string, to: string): Promise<{ day: string; available: number }[]>;
}
