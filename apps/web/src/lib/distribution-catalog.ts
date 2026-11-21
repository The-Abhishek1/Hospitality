/** Product roadmap, not a list of live integrations. Only setup-enabled entries have a database preparation path. */
export type DistributionCategory = 'ota' | 'rental' | 'gds' | 'wholesale' | 'metasearch';
export type DistributionChannel = {
 key: string; name: string; category: DistributionCategory; brands: readonly string[];
 route: string; status: 'sandbox_adapter' | 'partner_contract' | 'planned'; setup: boolean;
 next: string; source?: string;
};
export const distributionCategories: readonly {key:DistributionCategory;name:string;description:string}[] = [
 {key:'ota',name:'Online travel agencies',description:'Two-way room availability, rates, restrictions and reservation delivery.'},
 {key:'rental',name:'Rentals & specialist stays',description:'Property-specific content, pricing and booking rules require their own contracts.'},
 {key:'gds',name:'Global distribution systems',description:'Hotel supply distribution through an approved CRS or representation connection; shopping APIs alone do not publish hotel inventory.'},
 {key:'wholesale',name:'Wholesalers & bed banks',description:'Supplier contracts, net rates, allotments, release periods and settlement.'},
 {key:'metasearch',name:'Metasearch & direct booking',description:'Price feeds and landing-page links, with bookings completed through an eligible booking route.'},
];
export const distributionChannels: readonly DistributionChannel[] = [
 {key:'agoda',name:'Agoda',category:'ota',brands:['Agoda'],route:'Agoda YCS supply API',status:'sandbox_adapter',setup:true,next:'Partner authorization and certification required. Products, rates and limited reservation workflows are implemented for sandbox testing.',source:'https://developer.agoda.com/supply/docs/introduction'},
 {key:'booking_com',name:'Booking.com',category:'ota',brands:['Booking.com'],route:'Booking.com Connectivity APIs',status:'sandbox_adapter',setup:true,next:'Approved partner access and test machine account. New-provider onboarding is currently paused.',source:'https://connect.booking.com/'},
 {key:'makemytrip',name:'MakeMyTrip / Goibibo',category:'ota',brands:['MakeMyTrip','Goibibo'],route:'inGo-MMT partner supply contract to confirm',status:'partner_contract',setup:true,next:'Obtain official supply API specification, sandbox access and certification requirements.'},
 {key:'expedia',name:'Expedia / Hotels.com',category:'ota',brands:['Expedia','Hotels.com'],route:'Expedia Group lodging supply connectivity',status:'planned',setup:false,next:'Confirm brand/property coverage, partner onboarding and certification scope.',source:'https://developers.expediagroup.com/supply/lodging'},
 {key:'yatra',name:'Yatra',category:'ota',brands:['Yatra'],route:'Supplier connectivity contract to confirm',status:'planned',setup:false,next:'Obtain supplier-side API documentation and sandbox access.'},
 {key:'easemytrip',name:'EaseMyTrip',category:'ota',brands:['EaseMyTrip'],route:'Supplier connectivity contract to confirm',status:'planned',setup:false,next:'Obtain supplier-side API documentation and sandbox access.'},
 {key:'traveloka',name:'Traveloka',category:'ota',brands:['Traveloka'],route:'Supplier connectivity contract to confirm',status:'planned',setup:false,next:'Confirm partner eligibility, API contract and property authorization.'},
 {key:'airbnb',name:'Airbnb',category:'rental',brands:['Airbnb'],route:'Approved software-partner connection to confirm',status:'planned',setup:false,next:'Confirm partnership eligibility and property-level capabilities. Calendar sync is not full rate / reservation connectivity.'},
 {key:'vrbo',name:'Vrbo',category:'rental',brands:['Vrbo'],route:'Vrbo software connectivity to confirm separately',status:'planned',setup:false,next:'Confirm rental-specific onboarding and certification; Expedia lodging access does not establish Vrbo access.'},
 {key:'hostelworld',name:'Hostelworld',category:'rental',brands:['Hostelworld'],route:'Specialist accommodation supply contract to confirm',status:'planned',setup:false,next:'Verify dorm / bed inventory model, supplier API and certification.'},
 {key:'bedandbreakfast',name:'Bedandbreakfast.eu / .nl',category:'rental',brands:['Bedandbreakfast.eu','Bedandbreakfast.nl'],route:'Partner connectivity and market coverage to confirm',status:'planned',setup:false,next:'Confirm current supported supplier connections and market-specific requirements.'},
 {key:'amadeus',name:'Amadeus',category:'gds',brands:['Amadeus'],route:'Hotel CRS / GDS distribution agreement',status:'planned',setup:false,next:'Agree supplier distribution route, hotel/chain codes and negotiated-rate support.'},
 {key:'sabre',name:'Sabre',category:'gds',brands:['Sabre'],route:'Hotel CRS / GDS distribution agreement',status:'planned',setup:false,next:'Confirm supplier connectivity, representation, certification and commission workflows.'},
 {key:'travelport',name:'Travelport',category:'gds',brands:['Travelport','Galileo','Worldspan'],route:'Hotel CRS / GDS distribution agreement',status:'planned',setup:false,next:'Confirm hotel supply access and network coverage.',source:'https://eportal.travelport.com/pages/HotelProducts.aspx'},
 {key:'hotelbeds',name:'Hotelbeds',category:'wholesale',brands:['Hotelbeds'],route:'Supplier distribution agreement',status:'planned',setup:false,next:'Obtain supplier push/pull contract; consumer Booking API credentials do not establish supplier access.',source:'https://developer.hotelbeds.com/'},
 {key:'webbeds',name:'WebBeds',category:'wholesale',brands:['WebBeds'],route:'Supplier distribution agreement',status:'planned',setup:false,next:'Confirm supplier API, net-rate contracts, allotments and booking notification rules.',source:'https://www.webbeds.com/suppliers/support/'},
 {key:'bonotel',name:'Bonotel',category:'wholesale',brands:['Bonotel'],route:'Supplier contract to confirm',status:'planned',setup:false,next:'Obtain supplier agreement and technical specification.'},
 {key:'grnconnect',name:'GRNconnect',category:'wholesale',brands:['GRNconnect'],route:'Supplier contract to confirm',status:'planned',setup:false,next:'Confirm hotel supply connectivity rather than travel-agent shopping access.'},
 {key:'travco',name:'Travco',category:'wholesale',brands:['Travco'],route:'Supplier contract to confirm',status:'planned',setup:false,next:'Obtain supplier agreement, allotment model and technical specification.'},
 {key:'hpro',name:'HPro Travel',category:'wholesale',brands:['HPro Travel'],route:'Supplier contract to confirm',status:'planned',setup:false,next:'Confirm provider identity, supplier onboarding, API scope and settlement model.'},
 {key:'google_hotels',name:'Google Hotels / Hotel Ads',category:'metasearch',brands:['Google Hotels','Google Hotel Ads','Free booking links'],route:'Hotel Center feeds and eligible booking-engine landing pages',status:'planned',setup:false,next:'Build public booking engine and accurate landing pages, then implement approved price-feed onboarding.',source:'https://developers.google.com/hotels/hotel-prices/dev-guide/ari-overview'},
 {key:'kayak',name:'KAYAK',category:'metasearch',brands:['Kayak'],route:'Metasearch partner agreement to confirm',status:'planned',setup:false,next:'Confirm rate-feed, click attribution and booking landing-page requirements.'},
 {key:'trivago',name:'trivago',category:'metasearch',brands:['Trivago'],route:'Metasearch / booking-engine connectivity to confirm',status:'planned',setup:false,next:'Confirm eligibility, price feed and direct-booking landing-page requirements.',source:'https://developer.trivago.com/fastconnect/fast-connect-overview.html'},
 {key:'tripadvisor',name:'Tripadvisor',category:'metasearch',brands:['Tripadvisor'],route:'Hotel metasearch / booking-engine partner route to confirm',status:'planned',setup:false,next:'Confirm current hotel price-comparison program, eligibility and technical contract.',source:'https://developer-tripadvisor.com/connectivity/solutions/index.html'},
];
export const distributionStatus = (status:DistributionChannel['status']) => status==='sandbox_adapter'?'Sandbox adapter · not certified':status==='partner_contract'?'Awaiting partner API contract':'Planned · not connected';
export function filterDistribution(q:string,category:string='all') {
 const search=q.trim().toLocaleLowerCase().slice(0,120);
 return distributionChannels.filter(c=>(category==='all'||c.category===category)&&[c.name,...c.brands,c.route].join(' ').toLocaleLowerCase().includes(search));
}
