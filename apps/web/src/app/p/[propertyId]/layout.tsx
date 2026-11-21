import { WorkspaceLayout } from '@/components/workspace/layout';
export default async function PropertyLayout({children,params}:{children:React.ReactNode;params:Promise<{propertyId:string}>}) {
  const {propertyId}=await params;
  return <WorkspaceLayout propertyId={propertyId}>{children}</WorkspaceLayout>;
}
