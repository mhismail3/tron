import type { ApprovalPresenter } from "../settings/tool-contract.js";
import { TRON_FORM_CAPABILITY, type FormCapableUI } from "./extension-adapter-contract.js";

/**
 * The semantic form that shows one approval request in the chat that asked
 * (#2050). Its single question is the request ID: the client renders the
 * request itself from `settings.approvals` in the shared approval sheet and
 * decides with `settings.decide`. The broker refuses answers to it, so the
 * approve/deny options only declare the vocabulary the form validator requires.
 */
export function approvalFormPresenter(context: { hasUI?: boolean; ui?: unknown } | undefined): ApprovalPresenter {
  const requestForm = context?.hasUI ? (context.ui as FormCapableUI)[TRON_FORM_CAPABILITY] : undefined;
  return ({ requestId, title }, signal) => {
    if (!requestForm) return Promise.reject(new Error("Waiting for approval needs an interactive Tron chat; ask with wait false instead"));
    return requestForm({ signal, form: {
      version: 1, title, allowCancel: false, presentation: "approval",
      questions: [{ id: requestId, question: "Approve this request?",
        options: [{ id: "approve", label: "Approve" }, { id: "deny", label: "Deny" }], multiSelect: false, allowOther: false }],
    } });
  };
}
