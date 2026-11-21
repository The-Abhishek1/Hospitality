import './globals.css';
export const metadata={title:'Your stay · Hospitality',description:'A personal space for your hotel stay.',manifest:'/manifest.webmanifest',robots:{index:false,follow:false},referrer:'no-referrer',appleWebApp:{capable:true,title:'Your stay',statusBarStyle:'default'},icons:{icon:[{url:'/icons/stay-192.png',sizes:'192x192',type:'image/png'},{url:'/icons/stay-512.png',sizes:'512x512',type:'image/png'}],apple:'/icons/stay-180.png'}};
export const viewport={width:'device-width',initialScale:1,viewportFit:'cover',themeColor:'#183457'};
export default function RootLayout({children}:{children:React.ReactNode}){return <html lang="en"><body>{children}</body></html>;}
