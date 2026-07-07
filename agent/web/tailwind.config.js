/** @type {import('tailwindcss').Config} */
module.exports = {
  content: ["./dist/index.html", "./dist/app.js"],
  theme: {
    extend: {
      colors: {
        bg: "var(--color-bg)",
        panel: "var(--color-panel)",
        "panel-soft": "var(--color-panel-soft)",
        "panel-muted": "var(--color-panel-muted)",
        ink: "var(--color-ink)",
        muted: "var(--color-muted)",
        faint: "var(--color-faint)",
        line: "var(--color-line)",
        "line-strong": "var(--color-line-strong)",
        brand: "var(--color-brand)",
        "brand-hover": "var(--color-brand-hover)",
        "brand-solid": "var(--color-brand-solid)",
        "on-brand": "var(--color-on-brand)",
        success: "var(--color-success)",
        "success-bg": "var(--color-success-bg)",
        "success-line": "var(--color-success-line)",
        warn: "var(--color-warn)",
        "warn-bg": "var(--color-warn-bg)",
        "warn-line": "var(--color-warn-line)",
        danger: "var(--color-danger)",
        "danger-bg": "var(--color-danger-bg)",
        "danger-line": "var(--color-danger-line)",
      },
    },
  },
  plugins: [],
};
