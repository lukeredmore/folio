# Folio Native OpenType LaTeX Math Showcase

Welcome to the **Native OpenType LaTeX Math (`SwiftMath`)** showcase! Move your cursor onto any inline `$...$` span or `$$...$$` display block to reveal and edit its raw $\text{LaTeX}$ source, then move off the line to see it typeset in **Latin Modern Math** with full OpenType `MATH` glyph tables.

---

## 1. Document-Scoped Macro Definitions (`\newcommand` & `\DeclareMathOperator`)

This block defines reusable document-wide macros—including positional arguments (`#1`, `#2`) and optional default arguments (`[1]`). Edit any macro below and watch every equation in the document update live:

$$
\newcommand{\R}{\mathbb{R}}
\newcommand{\C}{\mathbb{C}}
\newcommand{\N}{\mathbb{N}}
\newcommand{\E}{\mathbb{E}}
\newcommand{\Prob}{\mathbb{P}}
\newcommand{\calL}{\mathcal{L}}
\newcommand{\calN}{\mathcal{N}}
\newcommand{\norm}[1]{\left\lVert #1 \right\rVert}
\newcommand{\abs}[1]{\left\lvert #1 \right\rvert}
\newcommand{\ip}[2]{\left\langle #1, #2 \right\rangle}
\newcommand{\pdv}[3][1]{\frac{\partial^{#1} #2}{\partial #3^{#1}}}
\newcommand{\KL}[2]{D_{\mathrm{KL}}\left(#1 \,\middle\|\, #2\right)}
\DeclareMathOperator*{\argmin}{arg\,min}
\DeclareMathOperator*{\argmax}{arg\,max}
\DeclareMathOperator{\Tr}{Tr}
\DeclareMathOperator{\Cov}{Cov}
$$

---

## 2. Inline Math & Custom Macros in Prose

- **Hilbert Spaces & Norms**: For any vectors $u, v \in \R^n$ and operator $A \in \C^{m \times n}$, the Cauchy–Schwarz inequality states that $\abs{\ip{u}{v}} \le \norm{u}_2 \norm{v}_2$, while the Frobenius norm satisfies $\norm{A}_F = \sqrt{\Tr(A^* A)}$.
- **Parameterized & Optional-Argument Macros**: Using `\pdv` with its default order gives the first partial derivative $\pdv{u}{t}$, while passing the optional argument `[2]` produces the second partial derivative $\pdv[2]{u}{x} + \pdv[2]{u}{y} = 0$.
- **Font Alphabets**: Compare Roman $\mathrm{d}x$, Bold $\mathbf{F} = m\mathbf{a}$, Bold-Italic $\boldsymbol{\theta}^*$, Calligraphic $\mathcal{F}\{f(t)\}$, Blackboard Bold $\R, \C, \N, \mathbb{Z}, \mathbb{Q}$, Fraktur $\mathfrak{su}(2) \oplus \mathfrak{u}(1)$, Sans-Serif $\mathsf{T}_{\mu\nu}$, and Monospace $\mathtt{O(n \log n)}$.

---

## 3. Multi-Line Aligned Derivations & Equation Tags (`align` & `\tag`)

### Regularized Least-Squares & Ridge Regression Objective
$$
\theta^* = \argmin_{\theta \in \R^d} \left\{ \frac{1}{2n} \norm{X\theta - y}_2^2 + \frac{\lambda}{2} \norm{\theta}_2^2 \right\} = (X^\top X + n\lambda I_d)^{-1} X^\top y \tag{1}
$$

### Variational Autoencoder (ELBO) Multi-Line Derivation
$$
\begin{align}
\log p_\theta(x) &= \E_{q_\phi(z \mid x)}\left[ \log \frac{p_\theta(x, z)}{q_\phi(z \mid x)} \right] + \KL{q_\phi(z \mid x)}{p_\theta(z \mid x)} \\
&\ge \E_{q_\phi(z \mid x)}\left[ \log p_\theta(x \mid z) \right] - D_{\mathrm{KL}}\left( q_\phi(z \mid x) \parallel p(z) \right) \\
&\equiv \calL_{\mathrm{ELBO}}(\theta, \phi; x)
\end{align} \tag{2}
$$

---

## 4. Matrices, Determinants & Linear Algebra (`pmatrix`, `bmatrix`, `vmatrix`, `Vmatrix`)

### Singular Value Decomposition & Block Matrices
$$
U \Sigma V^\top = \begin{pmatrix}
u_{11} & u_{12} & \cdots & u_{1r} \\
u_{21} & u_{22} & \cdots & u_{2r} \\
\vdots & \vdots & \ddots & \vdots \\
u_{m1} & u_{m2} & \cdots & u_{mr}
\end{pmatrix}
\begin{bmatrix}
\sigma_1 & 0 & \cdots & 0 \\
0 & \sigma_2 & \cdots & 0 \\
\vdots & \vdots & \ddots & \vdots \\
0 & 0 & \cdots & \sigma_r
\end{bmatrix}
\begin{pmatrix}
v_{11} & v_{21} & \cdots & v_{n1} \\
v_{12} & v_{22} & \cdots & v_{n2} \\
\vdots & \vdots & \ddots & \vdots \\
v_{1r} & v_{2r} & \cdots & v_{nr}
\end{pmatrix} \tag{3}
$$

### Jacobian Determinant & Wronskian (`vmatrix`)
$$
\det J_F(r, \theta, \phi) = \begin{vmatrix}
\dfrac{\partial x}{\partial r} & \dfrac{\partial x}{\partial \theta} & \dfrac{\partial x}{\partial \phi} \\
\dfrac{\partial y}{\partial r} & \dfrac{\partial y}{\partial \theta} & \dfrac{\partial y}{\partial \phi} \\
\dfrac{\partial z}{\partial r} & \dfrac{\partial z}{\partial \theta} & \dfrac{\partial z}{\partial \phi}
\end{vmatrix} = \begin{vmatrix}
\sin\theta\cos\phi & r\cos\theta\cos\phi & -r\sin\theta\sin\phi \\
\sin\theta\sin\phi & r\cos\theta\sin\phi & r\sin\theta\cos\phi \\
\cos\theta & -r\sin\theta & 0
\end{vmatrix} = r^2 \sin\theta \tag{4}
$$

---

## 5. Piecewise Functions (`cases`)

### Soft-Thresholding (Proximal Operator of $\ell_1$ Norm)
$$
\mathcal{S}_\lambda(x)_i = \argmin_{z \in \R} \left\{ \frac{1}{2}(z - x_i)^2 + \lambda \abs{z} \right\} = \begin{cases}
x_i - \lambda & \text{if } x_i > \lambda, \\
0 & \text{if } \abs{x_i} \le \lambda, \\
x_i + \lambda & \text{if } x_i < -\lambda.
\end{cases} \tag{5}
$$

---

## 6. Large Operators, Multi-Line Subscripts (`\substack`), Radicals & Continued Fractions

### Prime Zeta Product & Ramanujan Continued Fraction
$$
\zeta(s) = \sum_{n=1}^{\infty} \frac{1}{n^s} = \prod_{\substack{p \in \N \\ p \text{ prime}}} \frac{1}{1 - p^{-s}}, \qquad
\cfrac{1}{1 + \cfrac{e^{-2\pi}}{1 + \cfrac{e^{-4\pi}}{1 + \cfrac{e^{-6\pi}}{1 + \cdots}}}} = \left( \sqrt{\frac{5 + \sqrt{5}}{2}} - \frac{\sqrt{5} + 1}{2} \right) e^{2\pi/5} \tag{6}
$$

### Generalized Stokes' Theorem, Residue Theorem & Gaussian Integral
$$
\oint_{\partial \Omega} \omega = \int_{\Omega} \mathrm{d}\omega, \qquad
\oint_{\gamma} f(z)\,\mathrm{d}z = 2\pi i \sum_{k=1}^{m} \mathrm{Ind}_\gamma(z_k)\,\mathrm{Res}(f, z_k), \qquad
\int_{\R^d} \exp\left(-\frac{1}{2}(x - \mu)^\top \Sigma^{-1} (x - \mu)\right)\mathrm{d}x = \sqrt{(2\pi)^d \det \Sigma} \tag{7}
$$

---

## 7. Classical & Quantum Physics Equations

### Incompressible Navier–Stokes & Einstein Field Equations
$$
\rho \left( \pdv{\mathbf{u}}{t} + (\mathbf{u} \cdot \nabla)\mathbf{u} \right) = -\nabla p + \mu \nabla^2 \mathbf{u} + \mathbf{f}, \qquad
R_{\mu\nu} - \frac{1}{2} R g_{\mu\nu} + \Lambda g_{\mu\nu} = \frac{8\pi G}{c^4} T_{\mu\nu} \tag{8}
$$

### Time-Dependent Schrödinger Equation & Path Integral Propagator
$$
i\hbar \pdv{}{t}\ket{\Psi(t)} = \left( -\frac{\hbar^2}{2m}\nabla^2 + V(\hat{\mathbf{r}}, t) \right)\ket{\Psi(t)}, \qquad
K(x_f, t_f; x_i, t_i) = \int_{x(t_i)=x_i}^{x(t_f)=x_f} \mathcal{D}[x(t)] \exp\left( \frac{i}{\hbar} \int_{t_i}^{t_f} \calL(x, \dot{x}, t)\,\mathrm{d}t \right) \tag{9}
$$
