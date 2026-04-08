# LCARS Design Audit & Recommendations

**Audit Date:** 2026-01-08
**Auditor:** Commander Jett Reno
**Sources Reviewed:**
1. thelcars.com - 56 colors across 4 themes
2. Bracer Jack - "Creating a Coherent LCARS Interface"
3. Bracer Jack - "The LCARS Manifesto"
4. LCARS 47 - "LCARS 101: A Designer's Handbook" by Eleanor C. Davenport

---

## Executive Summary

Our current LCARS implementation is **functional and visually appealing**, but deviates from canon LCARS standards in several measurable ways. This document outlines specific discrepancies and recommends changes—prioritized by impact and effort.

**Verdict:** Most deviations are intentional design choices for our use case (modern web app vs. 90s TV prop). However, some adjustments would improve authenticity without sacrificing usability.

---

## 1. DIMENSION COMPARISONS

### Button & Component Sizing

| Element | Canon (LCARS 101) | Our Current | Deviation | Priority |
|---------|-------------------|-------------|-----------|----------|
| **Base Button** | 150 × 60px | Variable, min-height 40px | Smaller height | LOW |
| **Gap/Spacing** | 5px | 6px | +1px | LOW |
| **Bar Height** | 30px | 40px | +10px | MEDIUM |
| **Elbow Outer Curve** | 150px diameter | 80px (--elbow-curve) | Smaller | MEDIUM |
| **Elbow Inner Curve** | 75px (50% of outer) | 30px (--corner-radius) | Much smaller | MEDIUM |
| **Sidebar Width** | Not specified | 200px | N/A | N/A |

### Recommended Changes:

1. **Bar Height** - Consider reducing from 40px to 30px for more authentic proportions
   - **Impact:** Significant visual change
   - **Effort:** Low (CSS variable change)
   - **Risk:** May affect readability on mobile

2. **Gap/Spacing** - Keep at 6px (5px is too tight for modern displays)
   - **Recommendation:** NO CHANGE - our 6px is more practical

3. **Elbow Curves** - Our curves are proportionally smaller
   - **Recommendation:** Optional enhancement, not critical

---

## 2. TYPOGRAPHY COMPARISONS

### Font Family

| Aspect | Canon | Our Current | Assessment |
|--------|-------|-------------|------------|
| **Primary Font** | Helvetica Ultra Compressed | Antonio | ACCEPTABLE |
| **Fallback** | N/A | Arial, sans-serif | Good |

**Analysis:** Antonio is a widely-used LCARS-inspired font that's freely available. Helvetica Ultra Compressed is expensive ($35+ per weight) and harder to license for web. **Antonio is the right choice.**

### Font Sizes

| Canon Rule | Our Implementation | Compliance |
|------------|-------------------|------------|
| **Only 3 sizes** (Title/Subtitle/Body) | 6 sizes (xs, sm, md, lg, xl, 2xl) | NON-COMPLIANT |

**Our Current Sizes:**
```css
--lcars-text-xs: 10px
--lcars-text-sm: 12px
--lcars-text-md: 14px
--lcars-text-lg: 18px
--lcars-text-xl: 24px
--lcars-text-2xl: 32px
```

### Recommended Changes:

1. **Consolidate to 3 Primary Sizes:**
   ```css
   --lcars-title: 24px      /* Headlines, section titles */
   --lcars-subtitle: 16px   /* Subheadings, emphasis */
   --lcars-body: 12px       /* UI text, labels, values */
   ```

2. **Keep utility sizes for edge cases** but document that they're non-canon
   - **Impact:** Moderate - requires reviewing all text sizing
   - **Effort:** Medium
   - **Priority:** MEDIUM

---

## 3. COLOR COMPARISONS

### Our Color Palette vs. Canon

| Color | Our Value | TNG Original | TNG Later | Assessment |
|-------|-----------|--------------|-----------|------------|
| **Blue** | #9999ff | #9999CC | #9999FF | MATCHES Later TNG |
| **Cyan** | #99ccff | #99CCFF | #99CCFF | EXACT MATCH |
| **Orange** | #ff9900 | #FF9900 | #FF9900 | EXACT MATCH |
| **Peach** | #ffcc99 | #FFCC99 | #FFCC99 | EXACT MATCH |
| **Tan** | #cc9966 | #CC9966 | #CC9966 | EXACT MATCH |
| **Purple** | #cc99ff | #CC99CC | #CC99FF | MATCHES Later TNG |
| **Lavender** | #ccccff | #CCCCFF | #CCCCFF | EXACT MATCH |
| **Red** | #cc4444 | #CC6666 | #CC6666 | SLIGHTLY DIFFERENT |
| **Crimson** | #ff4466 | N/A | N/A | CUSTOM (Main Event) |
| **Green** | #99ff99 | #99FF99 | #99FF99 | EXACT MATCH |
| **Yellow** | #ffff99 | #FFFF99 | #FFFF99 | EXACT MATCH |

### Color Usage Analysis

| Canon Rule | Our Implementation | Compliance |
|------------|-------------------|------------|
| **1-5 colors per screen** | 6+ colors active | NON-COMPLIANT |
| **One theme column only** | Mixed Later TNG + custom | PARTIALLY COMPLIANT |
| **Status colors distinct** | Green/Yellow/Red clearly separated | COMPLIANT |

### Recommended Changes:

1. **Reduce active colors per view** - Currently using too many simultaneously
   - Each section should emphasize 2-3 colors max
   - **Priority:** MEDIUM

2. **Standardize on Later TNG palette** - We're mostly there
   - Adjust `--lcars-red` from #cc4444 to #CC6666 for canon compliance
   - **Priority:** LOW (our red works well for Main Event branding)

3. **Document custom colors** - Crimson, Rose, etc. are intentional additions
   - **Action:** Add comments noting these are extensions
   - **Priority:** LOW

---

## 4. FRAME STRUCTURE (Bracer Jack Rules)

### Thick-Thin-Thick Rule

**Canon:** Frame thickness must follow thick → thin → thick pattern. NEVER use same thickness on turns.

| Element | Our Implementation | Compliance |
|---------|-------------------|------------|
| **Main L-Frame** | Sidebar 200px → Bar 40px → Content edge | COMPLIANT |
| **Organization Panel** | Left 16px → Top 4px | COMPLIANT |
| **Division Container** | Left 4px → Top 16px | COMPLIANT (reversed) |
| **Top Frame** | Sidebar 200px → Bar 8px | COMPLIANT |

**Assessment:** Our frame structure follows the thick-thin-thick rule correctly.

### Cap (Elbow) Usage

**Canon:** Caps should only appear at corners where the frame changes direction. Never dead-end into nothing.

| Element | Assessment |
|---------|------------|
| **Main sidebar elbow** | COMPLIANT - curves into horizontal bar |
| **Top sidebar elbow** | COMPLIANT - curves into thin bar |
| **Organization panels** | COMPLIANT - L-frame with proper termination |

**Assessment:** Our cap usage is correct.

### Recommended Changes:

1. **None required** - Frame structure is well-designed
   - **Priority:** N/A

---

## 5. ANIMATION ANALYSIS

### Canon Rules (Bracer Jack)

1. **Animations must be < 1 second**
2. **No rearranging controls during animation**
3. **Subtle movement preferred**

### Our Current Animations

| Animation | Duration | Canon Compliant? |
|-----------|----------|------------------|
| `candy-pulse` | 0.3s | YES |
| `candy-alert` | 0.5s | YES |
| `status-pulse-offline` | 2s | NO |
| `status-pulse-warning` | 1.5s | NO |
| `slideInRight` | 0.3s | YES |
| `fadeInLogo` | 1s | NO (border) |
| `lcars-glow` | 2s | NO |
| `lcars-breathe` | 3s | NO |
| `lcars-red-alert` | 1s | NO (border) |
| `lcars-warp-in` | 0.5s | YES |
| `lcars-transport-in` | 0.8s | YES |
| `lcars-glitch` | 0.5s | YES |
| `lcars-tactical-sweep` | 2s | NO |

### Recommended Changes:

1. **Reduce long animation durations:**
   ```css
   /* Before */
   --lcars-glow-duration: 2s;
   --lcars-breathe-duration: 3s;

   /* After - Canon compliant */
   --lcars-glow-duration: 0.8s;
   --lcars-breathe-duration: 0.8s;
   ```
   - **Priority:** LOW (these are subtle background effects)

2. **Status pulse animations** - Keep at current duration for visibility
   - **Recommendation:** NO CHANGE - user safety > canon purity
   - 2s pulse for offline status is more noticeable

3. **Tactical radar sweep** - Keep at 2s
   - **Recommendation:** NO CHANGE - this is a data visualization, not UI feedback

4. **Add animation duration CSS variables** for easy adjustment:
   ```css
   --lcars-animation-fast: 0.3s;
   --lcars-animation-normal: 0.5s;
   --lcars-animation-slow: 0.8s;
   ```
   - **Priority:** MEDIUM

---

## 6. BUTTON CONFORMITY

### Canon Rules

1. **Buttons must conform to frame width** - buttons in a sidebar should match sidebar width
2. **Command buttons never larger than base button**
3. **End buttons (rounded) for auxiliary functions**

### Our Implementation

| Rule | Assessment |
|------|------------|
| **Sidebar buttons match width** | COMPLIANT - full sidebar width |
| **Command button sizing** | N/A - we don't have command button groups |
| **End buttons for auxiliary** | PARTIALLY COMPLIANT - we use rounded pills differently |

### Recommended Changes:

1. **Consider adding true LCARS end buttons** for auxiliary actions
   - Current: All buttons are rectangular with text
   - Canon: Pill-shaped end buttons for secondary actions
   - **Priority:** LOW

---

## 7. SPECIFIC RECOMMENDATIONS

### HIGH PRIORITY (Should Do)

| # | Change | Effort | Impact |
|---|--------|--------|--------|
| 1 | Add animation duration CSS variables | Low | Improves maintainability |
| 2 | Document custom colors as extensions | Low | Clarity for future devs |
| 3 | Review per-section color usage (limit to 3-4) | Medium | Better visual hierarchy |

### MEDIUM PRIORITY (Nice to Have)

| # | Change | Effort | Impact |
|---|--------|--------|--------|
| 4 | Consolidate font sizes to 3 primary + 2 utility | Medium | Canon compliance |
| 5 | Reduce bar height from 40px to 30px | Low | More authentic proportions |
| 6 | Add LCARS end buttons for auxiliary actions | Medium | Enhanced component library |

### LOW PRIORITY (Optional)

| # | Change | Effort | Impact |
|---|--------|--------|--------|
| 7 | Adjust `--lcars-red` to canon #CC6666 | Low | Purist compliance |
| 8 | Reduce subtle animation durations | Low | Canon compliance |
| 9 | Increase elbow curve radii | Medium | More dramatic curves |

---

## 8. WHAT WE'RE DOING RIGHT

These aspects of our implementation are excellent and should NOT change:

1. **Font choice (Antonio)** - Practical, free, looks authentic
2. **Color palette** - Matches Later TNG era closely
3. **Frame structure** - Proper thick-thin-thick pattern
4. **Cap/elbow usage** - Correct placement and purpose
5. **Accessibility** - prefers-reduced-motion support
6. **Responsive design** - Adapts well to different screens
7. **Organization theming** - Per-org colors with CSS variables
8. **Status indicators** - Clear green/yellow/red distinction
9. **Black background** - Authentic LCARS base
10. **Concave corner technique** - Proper radial-gradient implementation

---

## 9. IMPLEMENTATION PLAN

If approved, implement changes in this order:

### Phase 1: Documentation & Variables (1-2 hours)
- [ ] Add animation duration CSS variables
- [ ] Document custom colors in comments
- [ ] Add canon compliance notes to CSS

### Phase 2: Typography Consolidation (2-3 hours)
- [ ] Define 3 primary font sizes
- [ ] Audit all text sizing usage
- [ ] Update components to use primary sizes

### Phase 3: Color Refinement (1-2 hours)
- [ ] Review each section's color count
- [ ] Reduce simultaneous colors where possible
- [ ] Test visual hierarchy

### Phase 4: Dimension Adjustments (Optional)
- [ ] Test 30px bar height
- [ ] Evaluate larger elbow curves
- [ ] User testing for feedback

---

## 10. CONCLUSION

Our LCARS implementation is **85% canon-compliant** and highly functional for its purpose. The deviations are mostly intentional design choices for modern web usage.

**Recommended Action:** Implement Phase 1 and Phase 2 changes. Phase 3 and 4 are optional refinements.

The goal isn't perfect canon compliance—it's creating a usable, beautiful interface that captures the LCARS aesthetic while serving real users.

---

*"I've fixed worse with less. This just needs some polish."*
— Commander Jett Reno

