export default function StudioModeNav({ activeMode, spriteFx, onCharacter, onSpriteFx, creatorPortalUrl }) {
  return <div className="effect-studio-switch">
    <button type="button" className={activeMode === "character" ? "is-active" : ""} onClick={onCharacter}>Character Animation</button>
    {spriteFx?.visible && <button type="button" className={activeMode === "sprite-fx" ? "is-active" : ""} onClick={onSpriteFx}>
      {spriteFx.label}
    </button>}
    {creatorPortalUrl && <button type="button" onClick={() => window.open(creatorPortalUrl, "_blank", "noopener,noreferrer")}>Creator Portal ↗</button>}
  </div>;
}
 
