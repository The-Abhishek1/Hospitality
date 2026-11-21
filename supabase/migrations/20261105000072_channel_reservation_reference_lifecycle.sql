-- Preserve provider/review history if a reservation is removed during tenant teardown.
-- SET NULL also avoids depending on the ordering of tenant/property cascade triggers.
alter table public.channel_booking_state drop constraint channel_booking_state_reservation_id_fkey;
alter table public.channel_booking_state add constraint channel_booking_state_reservation_id_fkey
 foreign key(reservation_id) references public.reservations(id) on delete set null;
alter table public.channel_review_cases drop constraint channel_review_cases_reservation_id_fkey;
alter table public.channel_review_cases add constraint channel_review_cases_reservation_id_fkey
 foreign key(reservation_id) references public.reservations(id) on delete set null;
