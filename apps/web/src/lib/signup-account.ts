import{createHash}from'node:crypto';
import{createClient}from'@supabase/supabase-js';
export const duplicateSignupMessage='An account already exists with this email. Sign in or reset your password. If you have not confirmed it yet, use Resend confirmation email.';
export function duplicateSignup(user:{identities?:unknown[]}|null,error?:{code?:string}|null){return ['user_already_exists','email_exists','email_exists_confirmed'].includes(error?.code??'')||Boolean(user&&Array.isArray(user.identities)&&user.identities.length===0);}
export async function signupAccount(email:string,address:string){
 if(!process.env.SUPABASE_SERVICE_ROLE_KEY)return 'unavailable';
 const db=createClient(process.env.NEXT_PUBLIC_SUPABASE_URL!,process.env.SUPABASE_SERVICE_ROLE_KEY,{auth:{persistSession:false,autoRefreshToken:false}});
 const hash=createHash('sha256').update(address).digest('hex'),{data,error}=await db.rpc('signup_account_check',{p_email:email,p_address_hash:hash});
 return error?'unavailable':data as'new'|'exists'|'pending'|'limited';
}
