import { useEffect, useState } from "react";

export default function StudioAccountStatus({
  cloudReady,
  session,
  publishers = [],
  profile,
  state,
  oauthAvailability,
  onOAuth,
  onPasswordSignIn,
  onSetup,
  onPublisherSelect,
  onSignOut,
}) {
  const packagedDesktop = window.location.protocol === "file:" && Boolean(window.ocpStudio);
  const [emailOpen, setEmailOpen] = useState(false);
  const [email, setEmail] = useState("");
  const [password, setPassword] = useState("");
  const [publisherFormOpen, setPublisherFormOpen] = useState(false);
  const [publisherSlug, setPublisherSlug] = useState("");
  const [creatorDisplayName, setCreatorDisplayName] = useState("");
  const publisherId = publisherSlug ? `creator.${publisherSlug}` : "";
  const providerLabel = session?.user?.provider === "google"
    ? "Google"
    : session?.user?.provider === "azure"
      ? "Microsoft"
      : session ? "Authenticated" : "Not signed in";
  const displayName = profile?.displayName || session?.user?.displayName || session?.user?.email || "OCP Account";
  const statusLabel = profile?.publisherId
    ? `${providerLabel} · ${profile.publisherId}`
    : session && state.status === "error"
      ? `Creator setup failed · ${state.message}`
      : session
        ? `${providerLabel} · Creator setup required`
        : state.status === "error"
          ? `Sign-in failed · ${state.message}`
          : "Local mode · Sign in to publish";
  const authBusy = state.status === "signing-in";
  const setupBusy = state.status === "linking";
  const hasPublishers = Array.isArray(publishers) && publishers.length > 0;
  const needsFirstPublisher = Boolean(session) && state.status === "needs-profile" && !hasPublishers;
  const showPublisherForm = Boolean(session) && (needsFirstPublisher || publisherFormOpen);

  useEffect(() => {
    if (!session) setPublisherFormOpen(false);
    if (hasPublishers && state.status !== "needs-profile") setPublisherFormOpen(false);
  }, [session, hasPublishers, state.status]);

  async function submitPasswordSignIn(event) {
    event.preventDefault();
    if (authBusy || !email.trim() || password.length < 8) return;
    try {
      await onPasswordSignIn(email, password);
      setPassword("");
      setEmailOpen(false);
    } catch {
      // Creator Cloud state already carries the provider-safe error.
    }
  }

  async function submitPublisher(event) {
    event.preventDefault();
    try {
      await onSetup({ publisherId, displayName: creatorDisplayName });
      setPublisherSlug("");
      setCreatorDisplayName("");
      setPublisherFormOpen(false);
    } catch {
      // The setup dialog renders the provider-safe error from global state.
    }
  }

  return <div className="studio-account-global">
    <div className={`studio-account-chip ${session ? "is-online" : "is-offline"}`}>
      <span className="studio-account-dot" />
      <div>
        <strong>{cloudReady ? displayName : "OCP Account"}</strong>
        <small>{cloudReady ? statusLabel : "Cloud not configured"}</small>
      </div>
    </div>
    {cloudReady && <div className="studio-account-actions">
      {!session && oauthAvailability.google && <button type="button" className="studio-button studio-account-action" onClick={() => onOAuth("google")} disabled={authBusy}>{authBusy ? "Google sign-in…" : "Continue with Google"}</button>}
      {!session && oauthAvailability.microsoft && <button type="button" className="studio-button studio-account-action" onClick={() => onOAuth("microsoft")} disabled={authBusy}>{authBusy ? "Microsoft sign-in…" : "Continue with Microsoft"}</button>}
      {!session && <button type="button" className="studio-button studio-account-action" aria-expanded={emailOpen} onClick={() => setEmailOpen((value) => !value)} disabled={authBusy}>Email sign in</button>}
      {session && hasPublishers && <select
        className="studio-publisher-switcher"
        aria-label="Active Publisher"
        value={profile?.publisherId || ""}
        disabled={setupBusy}
        onChange={(event) => { void onPublisherSelect(event.target.value).catch(() => {}); }}
      >
        {publishers.map((item) => <option key={item.publisherId} value={item.publisherId}>{item.displayName || item.publisherId} · {item.publisherId}</option>)}
      </select>}
      {session && hasPublishers && <button type="button" className="studio-button studio-account-action" onClick={() => setPublisherFormOpen((value) => !value)} disabled={setupBusy}>{publisherFormOpen ? "Cancel Publisher" : "+ Publisher"}</button>}
      {session && profile && state.status === "needs-signer" && <button type="button" className="studio-button studio-account-action studio-primary" onClick={() => onSetup({})} disabled={setupBusy}>{setupBusy ? "Linking…" : "Link this PC"}</button>}
      {session && <button type="button" className="studio-button studio-account-action" onClick={onSignOut}>Sign out</button>}
    </div>}
    {showPublisherForm && <form className="studio-email-auth" onSubmit={submitPublisher}>
      <strong>{hasPublishers ? "Add Creator publisher" : "Create Creator publisher"}</strong>
      <small>{hasPublishers
        ? "Add another Publisher to this OCP Account. Each Publisher keeps its own protected signing identity."
        : "Choose a public creator.<public-id> after signing in. This is a Marketplace Publisher ID, not your login name or email."}</small>
      <div className="studio-package-id studio-publisher-id">
        <span className="studio-package-prefix">creator.</span>
        <input value={publisherSlug} placeholder="user-xxxxxxxx" onChange={(event) => setPublisherSlug(event.target.value.toLowerCase().replace(/^creator\./, "").replace(/[^a-z0-9.-]/g, ""))} disabled={setupBusy} />
      </div>
      <small className="studio-publisher-full-id">{publisherId || "creator.<public-id>"}</small>
      <input value={creatorDisplayName} placeholder="Creator display name" onChange={(event) => setCreatorDisplayName(event.target.value)} disabled={setupBusy} />
      {publisherId === "creator.ocp" && <div className="studio-account-error" role="alert"><strong>Reserved Publisher</strong><small>creator.ocp is reserved for the verified OCP Official account.</small></div>}
      {state.status === "error" && <div className="studio-account-error" role="alert"><strong>Creator setup failed</strong><small>{state.message || "Could not create this Creator publisher."}</small></div>}
      <button type="submit" className="studio-button studio-primary" disabled={setupBusy || publisherId === "creator.ocp" || !/^creator\.[a-z0-9]+(?:[.-][a-z0-9]+)*$/.test(publisherId)}>{setupBusy ? "Setting up…" : hasPublishers ? "Add Publisher" : "Create Creator publisher"}</button>
    </form>}
    {!session && cloudReady && emailOpen && <form className="studio-email-auth" onSubmit={submitPasswordSignIn}>
      <strong>{packagedDesktop ? "OCP Desktop Creator sign in" : "Creator email sign in"}</strong>
      <small>{packagedDesktop ? "Google/Microsoft sign-in opens in your browser and returns securely to OCP Studio. Email/password remains available as a fallback." : "Use the same OCP Account email credentials."}</small>
      <input type="email" autoComplete="email" value={email} placeholder="email@example.com" onChange={(event) => setEmail(event.target.value)} disabled={authBusy} />
      <input type="password" autoComplete="current-password" value={password} placeholder="Password" onChange={(event) => setPassword(event.target.value)} disabled={authBusy} />
      <button type="submit" className="studio-button studio-primary" disabled={authBusy || !email.trim() || password.length < 8}>{authBusy ? "Signing in…" : "Sign in"}</button>
    </form>}
  </div>;
}
