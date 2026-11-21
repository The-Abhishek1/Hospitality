-- Fix: inside the subquery, unqualified "id" resolved to tasks.id, so assignees never saw their linked request.
drop policy guest_requests_select on public.guest_requests;
create policy guest_requests_select on public.guest_requests for select to authenticated using (
  private.has_permission(guest_requests.property_id, 'guest_requests.read')
  or exists (select 1 from public.tasks t
             where t.guest_request_id = guest_requests.id and t.assignee_id = (select auth.uid()))
);
