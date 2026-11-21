import { notFound, redirect } from 'next/navigation';
import { createClient } from '@/lib/supabase/server';
import { WorkspaceFrame, type WorkspaceProperty, type WorkspacePermissions } from './frame';
export async function WorkspaceLayout({children,propertyId,tenantId}: {children:React.ReactNode;propertyId?:string;tenantId?:string}) {
  const db=await createClient();
  const {data:{user}}=await db.auth.getUser();
  if(!user) redirect('/login');
  const {data:properties,error}=await db.from('properties').select('id,tenant_id,name,timezone,currency').order('name');
  if(error) throw new Error('Could not load hotel workspace. Please refresh.');
  const property=(propertyId ? properties?.find(p=>p.id===propertyId && (!tenantId || p.tenant_id===tenantId)) : properties?.find(p=>p.tenant_id===tenantId)) as WorkspaceProperty|undefined;
  if(!property){if(tenantId) return <main className="dash-fallback">{children}</main>;notFound();}
  const [{data:tenant},{data:membership},{data:permissions,error:permissionError},{data:platformAdmin}]=await Promise.all([
    db.from('tenants').select('name').eq('id',property.tenant_id).maybeSingle(),
    db.from('tenant_memberships').select('role').eq('tenant_id',property.tenant_id).eq('user_id',user.id).maybeSingle(),
    db.rpc('workspace_permissions',{p_property:property.id}),
    db.from('platform_admins').select('user_id').eq('user_id',user.id).maybeSingle(),
  ]);
  if(permissionError) throw new Error('Could not load workspace navigation. Please refresh.');
  const name=typeof user.user_metadata?.full_name==='string' ? user.user_metadata.full_name.split(' ')[0] : 'Team member';
  return <WorkspaceFrame platformAccess={!!platformAdmin} properties={properties ?? []} property={property} name={name} tenantName={tenant?.name ?? ''} permissions={(permissions ?? {}) as WorkspacePermissions} teamAccess={membership?.role==='owner'||membership?.role==='admin'}>{children}</WorkspaceFrame>;
}
