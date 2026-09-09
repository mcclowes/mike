"use client";

import {
  MarkdownEditor,
  type MarkdownEditorProps,
} from "@/app/components/ui/markdown-editor";
export function WorkflowPromptEditor({
  className,
  ...props
}: MarkdownEditorProps) {
  return (
    <MarkdownEditor
      {...props}
      ariaLabel={props.ariaLabel ?? "Workflow prompt"}
      className={className}
      // The workflow prompt pipeline never accepted these constructs; the
      // dedicated editor this wrapper replaced disabled them, so keep that.
      starterKit={{
        codeBlock: false,
        code: false,
        blockquote: false,
        horizontalRule: false,
        ...props.starterKit,
      }}
    />
  );
}
