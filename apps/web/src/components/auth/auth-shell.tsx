import Link from 'next/link';
export function AuthShell({ children }: { children: React.ReactNode }) {
  return <main className="auth-shell">
    <aside className="auth-story" aria-label="Hospitality Platform">
      <Link href="/login" className="auth-brand"><span className="auth-brand-mark" aria-hidden="true">h<span>·</span></span> hospitality<span className="auth-brand-light"> / workspace</span></Link>
      <div className="auth-story-content">
        <span className="auth-eyebrow"><span /> THE ART OF RUNNING A GREAT STAY</span>
        <h1>More hospitality.<br /><em>Less busywork.</em></h1>
        <p>Bring your front desk, guest conversations, and daily operations together. Make room for what matters.</p>
        <div className="auth-illustration" aria-hidden="true">
          <div className="auth-illustration-top"><span>YOUR HOTEL, IN HARMONY</span><span>● ● ●</span></div>
          <div className="auth-room-row"><span className="auth-room-icon">↗</span><div><strong>A seamless arrival</strong><small>Reservations & front desk</small></div><span className="auth-pill">Ready for check-in</span></div>
          <div className="auth-room-row"><span className="auth-room-icon">✧</span><div><strong>A thoughtful response</strong><small>Guest conversations & requests</small></div><span className="auth-dot" /></div>
          <div className="auth-room-row"><span className="auth-room-icon">✓</span><div><strong>A well-run day</strong><small>Rooms, tasks & billing</small></div><span className="auth-dot" /></div>
        </div>
        <div className="auth-story-note"><span aria-hidden="true">✳</span> Thoughtful tools for the people behind every stay.</div>
      </div>
      <footer className="auth-story-footer"><span>Built for better stays.</span><span>HOTEL OPERATIONS, TOGETHER</span></footer>
    </aside>
    <section className="auth-main"><Link href="/login" className="auth-mobile-brand">h<span>·</span> hospitality</Link><div className="auth-form-wrap">{children}</div><p className="auth-bottom-note">Your workspace. Your team. Every guest, taken care of.<br/><Link href="/privacy">Privacy policy</Link><span aria-hidden="true"> · </span><Link href="/data-deletion">Data deletion</Link></p></section>
  </main>;
}
