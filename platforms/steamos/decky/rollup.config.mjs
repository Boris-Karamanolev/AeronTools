import typescript from "@rollup/plugin-typescript";

export default {
  input: "src/index.tsx",
  output: {
    file: "dist/index.js",
    format: "es",
    inlineDynamicImports: true,
  },
  external: [
    "react",
    "react-dom",
    "react/jsx-runtime",
    "react/jsx-dev-runtime",
    "@decky/ui",
    "@decky/api",
  ],
  plugins: [
    typescript({
      tsconfig: "./tsconfig.json",
      compilerOptions: {
        noEmit: false,
        declaration: false,
        declarationMap: false,
        sourceMap: false,
      },
    }),
  ],
};
