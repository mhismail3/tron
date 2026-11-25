// oxlint-disable no-control-regex -- these classes exist to refuse or strip control characters in untrusted input
export const CONTROL_CHARACTER = /[\u0000-\u001f\u007f]/u;
export const CONTROL_CHARACTERS = /[\u0000-\u001f\u007f]/gu;
export const CONTROL_CHARACTER_EXCEPT_LINE_BREAKS = /[\u0000-\u0008\u000b\u000c\u000e-\u001f\u007f]/u;
export const CONTROL_CHARACTER_RUNS = /[\u0000-\u001f\u007f]+/gu;
