export default function WorkflowSidebar({ steps, step, onStep, desktop }) {
  return <aside className="studio-sidebar">
    <div className="studio-side-title">Workflow</div>
    {steps.map((name, index) => <button
      type="button"
      key={name}
      className={"studio-step " + (step === index ? "is-current " : "") + (index < step ? "is-done" : "")}
      onClick={() => onStep(index)}
    >
      <span>{index + 1}</span>{name}
    </button>)}
    <details className="studio-side-guide">
      <summary>How to use</summary>
      <ol>
        <li>Create a character project.</li>
        <li>Import Standard, Optional, or Custom animation videos.</li>
        <li>Set timing, cleanup, and anchor.</li>
        <li>Compose sprite sheets and preview Runtime behavior.</li>
        <li>Build the local .ocp package and test it in Runtime.</li>
        <li>Sign in to your OCP Account; this PC provisions its protected signing key.</li>
        <li>Sign + Upload + Validate in Creator Cloud.</li>
        <li>Open Creator Portal and submit for C8 review.</li>
        <li>After approval, verify the release in OCP Store and Desktop Runtime.</li>
      </ol>
    </details>
    <div className="studio-side-note">{desktop ? "Electron Desktop Studio" : "Browser Preview"}<br /><small>Source MP4 stays local</small></div>
  </aside>;
}

