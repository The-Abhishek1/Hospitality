// Switching hotels starts at its overview, where navigation reflects that hotel's permissions.
export const hotelOverview=(id:string)=>`/dashboard?property=${encodeURIComponent(id)}`;
export function propertyInitials(name:string){return name.trim().split(/\s+/).filter(Boolean).slice(0,2).map(word=>Array.from(word)[0]).join('').toUpperCase()||'H';}
export function filterProperties<T extends{name:string}>(properties:T[],query:string){const search=query.trim().toLocaleLowerCase();return search?properties.filter(p=>p.name.toLocaleLowerCase().includes(search)):properties;}
