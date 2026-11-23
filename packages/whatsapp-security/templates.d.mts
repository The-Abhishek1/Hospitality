export type ProviderTemplate={provider_id:string;name:string;language:string;category:string;provider_status:string;body:string;parameter_names:string[];supported:boolean;service_supported:boolean;definition:object};
export function normalizeTemplate(t:any):ProviderTemplate;
export function fetchTemplates(waba:string,token:string,version:string,fetcher?:typeof fetch):Promise<ProviderTemplate[]>;
