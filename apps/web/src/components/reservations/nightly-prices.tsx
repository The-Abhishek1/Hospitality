import{dayLabel,money}from'@/lib/reservations';
import'./nightly-prices.css';
export function NightlyPrices({nightly,currency}:{nightly?:{night:string;amount:number;custom:boolean;label:string}[];currency:string}){
 if(!nightly?.length)return null;
 return <details className="booking-nightly-prices"><summary>Price by night · {nightly.length} nights</summary><ul>{nightly.map(n=><li key={n.night}><span>{dayLabel(n.night)}{n.custom&&<small>{n.label||'Date-specific price'}</small>}</span><strong>{money(n.amount,currency)}</strong></li>)}</ul><small>Includes the selected rate plan. Checkout day is not charged.</small></details>;
}
