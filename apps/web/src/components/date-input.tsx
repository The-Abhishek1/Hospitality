'use client';
import {useId,useRef,useState,type InputHTMLAttributes,type ChangeEvent} from 'react';
import {displayDay,inputDay} from '@/lib/date-format';
type Props=Omit<InputHTMLAttributes<HTMLInputElement>,'type'|'value'|'defaultValue'> & {value?:string;defaultValue?:string};
export function DateInput({value,defaultValue='',name,onChange,min,max,disabled,required,id,...props}:Props){
 const uid=useId(),textInput=useRef<HTMLInputElement>(null),calendar=useRef<HTMLInputElement>(null),[draft,setDraft]=useState(displayDay(value??defaultValue)),[previous,setPrevious]=useState(value);
 if(value!==previous){setPrevious(value);setDraft(displayDay(value??''));}
 const iso=inputDay(draft),valid=(!draft&&!required)||!!iso&&(!min||iso>=String(min))&&(!max||iso<=String(max));
 function update(text:string,input?:HTMLInputElement){setDraft(text);const next=inputDay(text);(input??textInput.current)?.setCustomValidity((!text&&!required)||next&&(!min||next>=String(min))&&(!max||next<=String(max))?'':'Enter a valid date as DD-MM-YYYY within the allowed range.');if(next||!text)onChange?.({target:{value:next,name},currentTarget:{value:next,name}} as ChangeEvent<HTMLInputElement>);}
 return <span className="date-input"><input {...props} ref={textInput} id={id??uid} type="text" inputMode="numeric" placeholder="DD-MM-YYYY" maxLength={10} value={draft} required={required} disabled={disabled} pattern="[0-9]{2}-[0-9]{2}-[0-9]{4}" aria-invalid={draft&&!valid?true:undefined} onChange={e=>update(e.target.value,e.currentTarget)} onBlur={e=>update(e.target.value,e.currentTarget)}/>{name&&<input type="hidden" name={name} value={iso} disabled={disabled}/>}<button type="button" className="date-picker-button" aria-label="Choose a date" disabled={disabled} onClick={()=>{try{calendar.current?.showPicker();}catch{calendar.current?.focus();}}}>▦</button><input ref={calendar} type="date" aria-label="Calendar" tabIndex={-1} className="date-native-picker" value={iso} min={min} max={max} disabled={disabled} onChange={e=>update(displayDay(e.target.value))}/></span>;
}
