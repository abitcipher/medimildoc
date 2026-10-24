# UI plan

Status: **agreed 2026-09-27**. Items are worked in order; each one is
checked in the browser (light and dark, desktop and phone width) before it
is committed.

## Done first: compact header controls (2026-09-27)

Language, theme and account each take one icon slot in the top bar, in the
style of Google's apps (`AppWeb.HeaderControls`):

- **Language:** globe icon; the menu lists languages by their own name
  (English, Français, Українська), current one checked. No flags: a
  language is not a country. Flags (e.g. flagicons.lipis.dev) can be added
  next to the names if wanted.
- **Theme:** the icon shows the current mode (sun, moon, or monitor for
  device default); the menu offers Light, Dark, Device default. Reacts
  instantly, client side.
- **Account:** avatar with initials in a colour derived from the email; the
  menu is an account card (name, email, role, access profiles, sign out).

Keyboard: Enter/Space opens, arrows move between entries, Escape closes and
returns focus to the button.

## Progress (2026-09-27)

| Item | Status |
|---|---|
| 1 Readable records | done — cards, translated labels, help tooltips |
| 2 Records by category | done — category chips |
| 3 Person summary strip | done — fitness, clearance, allergy chips |
| 4 Classification marking band | done — current palette |
| 5 Two-step Add record | done — picker grouped by category |
| 6 Active sidebar item | done — `aria-current` |
| 7 Users page | done — chips + access panel |
| 8 Role landing pages | done — start page widgets per permission (2026-09-27) |
| Sheets sidebar alignment | done |
| Tables at phone width | done — tables scroll inside their card |
| Home page | done — sign-in card / start page |

Details:

## Agreed plan

1. Readable records: label/value rendering from each kind's UI schema,
   translated labels, instead of the raw map.
2. Records grouped by category (Personnel, Pay & family, Readiness,
   Clearance, Medical, Vetting), showing only categories the user may read.
3. Summary strip on the person page: position, fitness status, clearance
   level and validity, allergy alert for users with medical access.
4. Classification marking band above and below classified content, NATO
   style. **Uses the current colour palette for now.** Future work: let
   the user choose a colour scheme (and give the marking band its
   conventional colours as one option); the theme menu in the top bar is
   where that choice would live.
5. Two-step "Add record": category, then kind, with translated names and a
   short description.
6. Active item highlighted in the sidebar.
7. Users page: profiles as chips with a small edit panel.
8. Role landing pages (line commander readiness overview, CISO recent
   access), after User ↔ Person linking.

Also in scope:

- **The Sheets sidebar (`/sheets`)** follows the main app on the key
  points: same header controls pattern, same typography, spacing,
  buttons and table style, same themes (its black theme stays available
  as one of them).
- **Tables at phone width:** the People, Organizations and Positions
  tables are wider than a 390 px screen and scroll the whole page
  sideways; they should scroll inside their own container or collapse to
  cards.
- The home page is still the Phoenix default page apart from its
  navigation; replace it with a real landing page (ties in with item 8).
