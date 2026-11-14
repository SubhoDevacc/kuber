import type { Abi, AbiParameter } from "viem";

type Raw = string | number | boolean | string[] | Record<string, unknown>;

function convert(param: AbiParameter, value: unknown): unknown {
  const { type } = param;
  if (type.endsWith("[]")) {
    if (!Array.isArray(value))
      throw new Error(`${param.name}: expected a list`);
    const inner = { ...param, type: type.slice(0, -2) } as AbiParameter;
    return value.map((v) => convert(inner, v));
  }
  if (type === "tuple" && "components" in param) {
    // A struct arrives as a JSON object keyed by field name (or a list in field order).
    const fields = param.components;
    const get = (c: AbiParameter, i: number) =>
      Array.isArray(value)
        ? value[i]
        : (value as Record<string, unknown> | null)?.[c.name ?? ""];
    const out: Record<string, unknown> = {};
    fields.forEach((c, i) => {
      out[c.name ?? String(i)] = convert(c, get(c, i));
    });
    return out;
  }
  if (type.startsWith("uint") || type.startsWith("int")) {
    if (typeof value === "boolean")
      throw new Error(`${param.name}: expected a number`);
    return BigInt(value as string | number);
  }
  if (type === "bool") {
    if (typeof value === "boolean") return value;
    if (value === "true" || value === 1 || value === "1") return true;
    if (value === "false" || value === 0 || value === "0") return false;
    throw new Error(`${param.name}: expected true or false`);
  }
  return value;
}

/** Turns the server's JSON args into viem args by the function's ABI input types (numbers -> bigint). */
export function toArgs(abi: Abi, functionName: string, args: Raw[]): unknown[] {
  const fn = abi.find(
    (item) =>
      item.type === "function" &&
      item.name === functionName &&
      item.inputs.length === args.length,
  );
  if (fn?.type !== "function") {
    throw new Error(`No ${functionName} with ${args.length} inputs`);
  }
  return fn.inputs.map((input, i) => convert(input, args[i]));
}
