; Zed native Outline Panel & Breadcrumbs query for Markdown (H1 - H6)
(section
  (atx_heading
    (atx_h1_marker) @context
    heading_content: (_) @name)) @item

(section
  (atx_heading
    (atx_h2_marker) @context
    heading_content: (_) @name)) @item

(section
  (atx_heading
    (atx_h3_marker) @context
    heading_content: (_) @name)) @item

(section
  (atx_heading
    (atx_h4_marker) @context
    heading_content: (_) @name)) @item

(section
  (atx_heading
    (atx_h5_marker) @context
    heading_content: (_) @name)) @item

(section
  (atx_heading
    (atx_h6_marker) @context
    heading_content: (_) @name)) @item

(section
  (setext_heading
    heading_content: (_) @name
    (setext_h1_underline) @context)) @item

(section
  (setext_heading
    heading_content: (_) @name
    (setext_h2_underline) @context)) @item

