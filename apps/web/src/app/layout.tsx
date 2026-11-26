import "./globals.css";

export const metadata = {
  title: "Hospitality Platform",
  applicationName: "Hospitality",
  icons: {
    icon: [{url:"/favicon.svg",type:"image/svg+xml",sizes:"any"},{url:"/favicon.ico",type:"image/x-icon",sizes:"16x16 32x32 48x48"},{url:"/icons/hospitality-192.png",type:"image/png",sizes:"192x192"}],
    shortcut: "/favicon.ico",
    apple: [{url:"/apple-touch-icon.png",sizes:"180x180",type:"image/png"}],
  },
};

export default function RootLayout({ children }: { children: React.ReactNode }) {
  return (
    <html lang="en">
      <body className="min-h-screen bg-slate-50 text-slate-900 antialiased">{children}</body>
    </html>
  );
}
