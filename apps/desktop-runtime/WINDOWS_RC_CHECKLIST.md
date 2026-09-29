# Windows Runtime V3 Release Candidate Checklist

## Automated

- [ ] Release layout validation passes
- [ ] Rust/GDExtension build passes
- [ ] CS-RT passes 5/5
- [ ] Package Layer test passes
- [ ] Runtime V3 tests pass 6/6
- [ ] Single Instance test passes
- [ ] Release report generated

## Startup

- [ ] Overlay starts transparent
- [ ] Debug mode starts correctly
- [ ] No duplicate Godot process
- [ ] No Godot splash/window remains
- [ ] Active character loads without manual refresh

## Character

- [ ] Bible loads
- [ ] Meowsom loads
- [ ] Character switching works
- [ ] Active character persists
- [ ] Position persists
- [ ] Scale persists
- [ ] Bubble anchor persists
- [ ] Hitbox is correct

## Interaction

- [ ] Drag works
- [ ] Hover menu appears
- [ ] Hover menu hides during drag
- [ ] Hover menu does not shake
- [ ] Bubble follows character
- [ ] Quick Panel works
- [ ] Character Picker works
- [ ] Click-through works
- [ ] Always-on-top works

## Lifecycle

- [ ] Hide to Tray
- [ ] Restore from Tray
- [ ] Quick Panel restore behavior is correct
- [ ] Exit works
- [ ] No Godot process remains
- [ ] Reopen after Exit works

## Package

- [ ] Install Bible
- [ ] Install Meowsom
- [ ] Reinstall same version
- [ ] Invalid hash rejected
- [ ] Missing entry rejected
- [ ] Traversal path rejected
