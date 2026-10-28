# HTML Blocks Showcase

Folio renders a self-contained HTML block in a live web view. Click a block (or move the caret onto it) to edit the source. Drag or double-click to select text in a block and comment on it.

## Stacked bar

The internal SSD is sold as 512 GB. Hover over a bar segment to see its value.

<div style="display:flex;gap:2px;height:28px;margin:12px 0 6px 0;">
<div title="Home folder: 193.9 GB" style="flex:193.9;background:#2a78d6;border-radius:4px 0 0 4px;"></div>
<div title="Dev volumes: 43.5 GB" style="flex:43.5;background:#eb6834;"></div>
<div title="/Applications: 41.9 GB" style="flex:41.9;background:#1baf7a;"></div>
<div title="/private/var: 39.3 GB" style="flex:39.3;background:#eda100;"></div>
<div title="Free: 51.1 GB" style="flex:51.1;border:1px dashed #b5b4ad;border-radius:0 4px 4px 0;"></div>
</div>

<p style="font-size:0.85em;">
<span style="color:#2a78d6;">&#9632;</span> Home folder &nbsp;
<span style="color:#eb6834;">&#9632;</span> Dev volumes &nbsp;
<span style="color:#1baf7a;">&#9632;</span> Applications &nbsp;
<span style="color:#eda100;">&#9632;</span> /private/var &amp; caches
</p>

## Table

<table>
<tr><th>Volume</th><th>Used</th><th>Share</th></tr>
<tr><td>Home folder</td><td>193.9 GB</td><td>43.7%</td></tr>
<tr><td>Dev volumes</td><td>43.5 GB</td><td>9.8%</td></tr>
<tr><td>Free</td><td>51.1 GB</td><td>11.5%</td></tr>
</table>

## Preformatted text

<pre>
$ du -sh ~/workplace
 43G    /Users/me/workplace
</pre>

## Native HTML

These keep their native rendering: inline tags such as <kbd>Cmd</kbd> + <kbd>K</kbd> and <mark>marked text</mark>, and a standalone image tag.

<img src="assets/folio_architecture.svg" alt="Architecture" width="320" height="80" />

The end.
