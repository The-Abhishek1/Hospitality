'use client';
import { useState } from 'react';
import { distributionCategories, filterDistribution, distributionStatus } from '@/lib/distribution-catalog';
export function DistributionCatalog() {
 const [q,setQ]=useState(''),[category,setCategory]=useState('all');
 const rows=filterDistribution(q,category);
 return <section className="distribution-catalog" aria-labelledby="distribution-heading">
  <div className="distribution-heading"><div><span className="sr-eyebrow">Distribution roadmap</span><h2 id="distribution-heading">Explore distribution channels</h2><p>See the integration route and next step for each channel. Planned entries cannot be connected yet.</p></div><span className="distribution-count" aria-live="polite">{rows.length} integration routes</span></div>
  <div className="distribution-filters"><label>Find a channel<input type="search" value={q} maxLength={120} onChange={e=>setQ(e.target.value)} placeholder="Search brands, e.g. Hotels.com or Galileo"/></label><label>Channel type<select value={category} onChange={e=>setCategory(e.target.value)}><option value="all">All channel types</option>{distributionCategories.map(c=><option key={c.key} value={c.key}>{c.name}</option>)}</select></label></div>
  {distributionCategories.filter(c=>rows.some(r=>r.category===c.key)).map(category=><div className="distribution-group" key={category.key}>
   <h3>{category.name}</h3><p>{category.description}</p><div className="distribution-grid">{rows.filter(r=>r.category===category.key).map(c=><article className="distribution-item" key={c.key}>
    <span className={`distribution-status ${c.status}`}>{distributionStatus(c.status)}</span><h4>{c.name}</h4><p className="distribution-route">{c.route}</p><p>{c.next}</p>
    {c.source&&<a href={c.source} target="_blank" rel="noreferrer">Official reference ↗</a>}
    {c.setup&&<a href="#channel-setup">Go to connection setup ↑</a>}
   </article>)}</div>
  </div>)}
  {!rows.length&&<div className="sr-empty"><h3>No matching channels</h3><p>Try a brand name or choose another channel type.</p><button className="dash-button" onClick={()=>{setQ('');setCategory('all');}}>Clear filters</button></div>}
 </section>;
}
