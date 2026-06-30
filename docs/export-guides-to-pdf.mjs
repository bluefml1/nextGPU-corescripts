import { mdToPdf } from 'md-to-pdf';
import { readFileSync } from 'fs';
import { dirname, join, resolve } from 'path';
import { fileURLToPath } from 'url';

const __dirname = dirname(fileURLToPath(import.meta.url));

const css = `
  body {
    font-family: "Segoe UI", Calibri, Arial, sans-serif;
    font-size: 11pt;
    line-height: 1.45;
    color: #1a1a1a;
    max-width: 100%;
  }
  h1 { font-size: 22pt; margin-top: 0; page-break-before: avoid; }
  h2 { font-size: 16pt; margin-top: 1.4em; page-break-after: avoid; }
  h3 { font-size: 13pt; page-break-after: avoid; }
  img {
    display: block;
    max-width: 100%;
    height: auto;
    margin: 0.75em auto;
    page-break-inside: avoid;
  }
  table {
    border-collapse: collapse;
    width: 100%;
    margin: 0.75em 0;
    font-size: 10pt;
    page-break-inside: avoid;
  }
  th, td {
    border: 1px solid #ccc;
    padding: 6px 8px;
    text-align: left;
    vertical-align: top;
  }
  th { background: #f3f3f3; }
  pre, code {
    font-family: Consolas, "Courier New", monospace;
    font-size: 9.5pt;
  }
  pre {
    background: #f6f8fa;
    padding: 10px;
    overflow-x: auto;
    page-break-inside: avoid;
  }
  blockquote {
    border-left: 4px solid #ddd;
    margin-left: 0;
    padding-left: 1em;
    color: #444;
  }
  a { color: #0366d6; word-break: break-all; }
  hr { border: none; border-top: 1px solid #ddd; margin: 1.5em 0; }
`;

const guides = [
  { input: 'setup-beginer.md', output: 'setup-beginer.pdf' },
  { input: 'machine-setup-beginer.md', output: 'machine-setup-beginer.pdf' },
];

for (const guide of guides) {
  const inputPath = resolve(__dirname, guide.input);
  const outputPath = resolve(__dirname, guide.output);
  const markdown = readFileSync(inputPath, 'utf8');

  console.log(`Exporting ${guide.input} -> ${guide.output} ...`);

  const pdf = await mdToPdf(
    { content: markdown },
    {
      basedir: __dirname,
      dest: outputPath,
      css,
      pdf_options: {
        format: 'A4',
        margin: { top: '18mm', right: '16mm', bottom: '18mm', left: '16mm' },
        printBackground: true,
      },
      launch_options: {
        args: ['--no-sandbox', '--disable-setuid-sandbox'],
      },
    }
  );

  if (!pdf?.filename) {
    throw new Error(`Failed to create ${guide.output}`);
  }

  console.log(`  OK: ${outputPath}`);
}

console.log('Done.');
