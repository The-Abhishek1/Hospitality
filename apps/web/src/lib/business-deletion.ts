import type {HotelDeletionPreview} from './hotel-deletion';
export type BusinessDeletionPreview = HotelDeletionPreview & {
  hotel_total: number; hotel_remaining: number; members: number; guest_profiles: number;
  invitations: number; custom_roles: number; subscription_records: number;
  hotels?: {id: string; name: string; state: string; files_remaining: number}[];
};
