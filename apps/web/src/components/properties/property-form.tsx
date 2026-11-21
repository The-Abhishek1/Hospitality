"use client";
import { useActionState,useState } from 'react';
import { createProperty,updateProperty,type PropertyState } from '@/app/properties/actions';
export type PropertyFields={id?:string;name:string;property_type:string;timezone:string;currency:string;address:string;city:string;country_code:string;contact_email:string;contact_phone:string};
export function PropertyForm({property,tenant,request,timezones,currencies,currencyLocked=false}:{property:PropertyFields;tenant?:string;request?:string;timezones:string[];currencies:string[];currencyLocked?:boolean}){
 const [values,setValues]=useState(property);
 const [state,action,pending]=useActionState(property.id?updateProperty:createProperty,{} as PropertyState);
 return <form action={action} className="property-form">
  {property.id&&<input type="hidden" name="property" value={property.id}/>}{tenant&&<input type="hidden" name="tenant" value={tenant}/>}{request&&<input type="hidden" name="request" value={request}/>}
  {state.error&&<p className="property-error" role="alert">{state.error}</p>}
  <fieldset disabled={pending}><legend>Property identity</legend><p className="property-help">The details your team uses to identify this hotel.</p><div className="property-form-grid">
  <label className="property-full">Property name<input name="name" required minLength={2} maxLength={120} value={values.name} onChange={e=>setValues({...values,name:e.target.value})} placeholder="e.g. Harbour View Hotel" autoComplete="organization"/></label>
  <label>Property type<select name="property_type" value={values.property_type} onChange={e=>setValues({...values,property_type:e.target.value})}><option value="hotel">Hotel</option><option value="resort">Resort</option><option value="hostel">Hostel</option><option value="homestay">Homestay</option></select></label>
  <label>Country code<input name="country_code" required minLength={2} maxLength={2} pattern="[A-Za-z]{2}" value={values.country_code} onChange={e=>setValues({...values,country_code:e.target.value})} autoComplete="country"/><small>Two-letter code, e.g. IN, GB, or US.</small></label>
  <label className="property-full">Street address<textarea name="address" maxLength={1000} rows={2} value={values.address} onChange={e=>setValues({...values,address:e.target.value})} autoComplete="street-address" placeholder="Street, area, building"/></label>
  <label>City<input name="city" maxLength={120} value={values.city} onChange={e=>setValues({...values,city:e.target.value})} autoComplete="address-level2"/></label>
  <label>Contact phone<input name="contact_phone" type="tel" maxLength={40} value={values.contact_phone} onChange={e=>setValues({...values,contact_phone:e.target.value})} autoComplete="tel" placeholder="+91…"/></label>
  <label className="property-full">Contact email<input name="contact_email" type="email" maxLength={254} value={values.contact_email} onChange={e=>setValues({...values,contact_email:e.target.value})} autoComplete="email" placeholder="frontdesk@yourhotel.com"/></label>
  </div></fieldset>
  <fieldset disabled={pending}><legend>Operational defaults</legend><p className="property-help">Dates and financial reporting use these hotel-level settings.</p><div className="property-form-grid">
  <label>Hotel timezone<input name="timezone" list="property-timezones" required value={values.timezone} onChange={e=>setValues({...values,timezone:e.target.value})}/><datalist id="property-timezones">{timezones.map(t=><option key={t} value={t}/>)}</datalist><small>Changing this changes how “today” is calculated. Existing stay dates stay as entered.</small></label>
  <label>Currency<select name="currency" value={values.currency} onChange={e=>setValues({...values,currency:e.target.value})} disabled={currencyLocked}>{currencies.map(c=><option key={c} value={c}>{c}</option>)}</select>{currencyLocked&&<input type="hidden" name="currency" value={property.currency}/>}<small>{currencyLocked?'Locked because bookings or orders exist. Historical amounts are never converted.':'Choose before you start taking bookings. Amounts are stored in this currency.'}</small></label>
  </div></fieldset>
  <div className="property-form-footer"><p>Only business owners and admins can change these settings.</p><button type="submit" className="dash-button" disabled={pending}>{pending?'Saving…':property.id?'Save property settings':'Create property'}</button></div>
 </form>;
}
