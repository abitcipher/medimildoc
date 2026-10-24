// The FSDC rule editor (docs/design/data-consistency.md): GoRules' JDM
// Editor mounted into the /rules/:key page by the RulesEditor LiveView hook.
// Loaded only on that page. Monaco (the code editor inside function nodes)
// comes from this bundle, never from a CDN.
import React, { useState } from "react";
import { createRoot } from "react-dom/client";
import { DecisionGraph, JdmConfigProvider } from "@gorules/jdm-editor";
import "@gorules/jdm-editor/dist/style.css";
import { loader } from "@monaco-editor/react";
import * as monaco from "monaco-editor";
import editorWorker from "monaco-editor/esm/vs/editor/editor.worker?worker";
import jsonWorker from "monaco-editor/esm/vs/language/json/json.worker?worker";
import tsWorker from "monaco-editor/esm/vs/language/typescript/ts.worker?worker";

self.MonacoEnvironment = {
  getWorker(_id, label) {
    if (label === "json") return new jsonWorker();
    if (label === "typescript" || label === "javascript") return new tsWorker();
    return new editorWorker();
  },
};
loader.config({ monaco });

function Editor({ initial, api, disabled }) {
  const [graph, setGraph] = useState(initial);
  const [simulate, setSimulate] = useState(undefined);
  api.setSimulate = setSimulate;
  api.getGraph = () => graph;

  return (
    <JdmConfigProvider>
      <DecisionGraph
        value={graph}
        disabled={disabled}
        simulate={simulate}
        onChange={(value) => {
          setGraph(value);
          api.onChange && api.onChange(value);
        }}
      />
    </JdmConfigProvider>
  );
}

// mount(element, {graph, disabled, onChange}) -> {getGraph, setSimulate, unmount}
export function mount(element, { graph, disabled = false, onChange }) {
  const api = { onChange };
  const root = createRoot(element);
  root.render(<Editor initial={graph} api={api} disabled={disabled} />);

  return {
    getGraph: () => api.getGraph && api.getGraph(),
    setSimulate: (value) => api.setSimulate && api.setSimulate(value),
    unmount: () => root.unmount(),
  };
}
