import StudioAccountStatus from "./StudioAccountStatus.jsx";
import StudioLanguageSwitch from "./StudioLanguageSwitch.jsx";
import StudioModeNav from "./StudioModeNav.jsx";

export default function StudioTopbar({
  activeMode,
  spriteFx,
  onCharacter,
  onSpriteFx,
  creatorPortalUrl,
  desktopBridge,
  desktopEnvironment,
  desktopActionBusy,
  onChooseWorkspace,
  project,
  cloudReady,
  session,
  publishers,
  profile,
  cloudState,
  oauthAvailability,
  onOAuth,
  onPasswordSignIn,
  onSetup,
  onPublisherSelect,
  onSignOut,
  locale,
  onLocaleChange,
}) {
  return <header className="studio-topbar">
    <div className="studio-brand"><span className="studio-orb" />OCP Animation Studio</div>
    <StudioModeNav
      activeMode={activeMode}
      spriteFx={spriteFx}
      onCharacter={onCharacter}
      onSpriteFx={onSpriteFx}
      creatorPortalUrl={creatorPortalUrl}
    />
    <div className="studio-topbar-right">
      <StudioLanguageSwitch locale={locale} onChange={onLocaleChange} />
      {desktopBridge && <div className="studio-desktop-host">
        <span>OCP Desktop</span>
        <small>{desktopEnvironment?.workspaceName ? "Local folder · " + desktopEnvironment.workspaceName : "No local folder selected"}</small>
        <button type="button" disabled={Boolean(desktopActionBusy)} onClick={onChooseWorkspace} title="Choose the local folder used for Studio project files and built .ocp packages.">
          {desktopActionBusy === "workspace" ? "Choosing…" : "Local folder"}
        </button>
      </div>}
      <div className="studio-meta">{project.name} · character/3 · {project.version}</div>
      <StudioAccountStatus
        cloudReady={cloudReady}
        session={session}
        publishers={publishers}
        profile={profile}
        state={cloudState}
        oauthAvailability={oauthAvailability}
        onOAuth={onOAuth}
        onPasswordSignIn={onPasswordSignIn}
        onSetup={onSetup}
        onPublisherSelect={onPublisherSelect}
        onSignOut={onSignOut}
      />
    </div>
  </header>;
}
 
