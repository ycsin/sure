require "application_system_test_case"

# A held item near the top or bottom of the scrolling box scrolls it, so it
# can be dropped past the rows that were on screen. Selenium cannot drive
# native drag and drop, so drags are dispatched DragEvents (as in RulesTest)
# and touches dispatched TouchEvents (as in SortableListTest).
class SortableListAutoscrollTest < ApplicationSystemTestCase
  setup do
    @user = users(:family_admin)
    page.driver.browser.manage.window.resize_to(1200, 700)
  end

  test "a rule dragged to the bottom edge scrolls the list and can be dropped below what was on screen" do
    rules = 30.times.map do |index|
      @user.family.rules.create!(name: "Rule #{format('%02d', index)}", resource_type: "transaction",
        actions: [ Rule::Action.new(action_type: "exclude_transaction") ])
    end
    sign_in @user
    visit rules_path
    first = "[data-sortable-list-id='rule:#{rules.first.id}']"
    assert_selector first

    result = page.evaluate_async_script(<<~JS, first)
      const [sourceSelector] = arguments;
      const done = arguments[arguments.length - 1];
      // The box that scrolls the list (the rules page's layout scrolls an
      // inner column, the dashboard #main).
      const scrollerOf = (element) => {
        for (let node = element.parentElement; node; node = node.parentElement) {
          if (/auto|scroll/.test(getComputedStyle(node).overflowY) && node.scrollHeight > node.clientHeight) return node;
        }
        return document.scrollingElement;
      };
      const source = document.querySelector(sourceSelector);
      const main = scrollerOf(source);
      const box = main.getBoundingClientRect();
      const bottom = Math.min(box.bottom, window.innerHeight);
      const x = box.left + box.width / 2;
      const dataTransfer = new DataTransfer();
      const fire = (element, type, y) => element.dispatchEvent(new DragEvent(type,
        { bubbles: true, cancelable: true, dataTransfer, clientX: x, clientY: y }));
      // A browser sends dragover repeatedly while the pointer is still.
      const holdAt = (y, ms, then) => {
        const timer = setInterval(() => fire(document.elementFromPoint(x, y) || main, "dragover", y), 50);
        setTimeout(() => { clearInterval(timer); then(); }, ms);
      };
      const start = main.scrollTop;
      const visibleRows = Array.from(document.querySelectorAll("[data-sortable-list-id^='rule:']"))
        .filter((row) => row.getBoundingClientRect().bottom <= bottom).length;

      fire(source, "dragstart", box.top + 10);
      holdAt(bottom - 8, 1000, () => {
        const scrolled = main.scrollTop - start;
        const middle = (box.top + bottom) / 2;
        holdAt(middle, 300, () => {
          const settled = main.scrollTop;
          holdAt(middle, 300, () => {
            // Measured before the drop, which moves the rows themselves.
            const stillWhileMiddle = main.scrollTop - settled;
            const target = document.elementFromPoint(x, middle);
            fire(target, "drop", middle);
            fire(source, "dragend", middle);
            done({ scrolled, stillWhileMiddle, visibleRows });
          });
        });
      });
    JS

    assert_operator result["scrolled"], :>, 200, "holding at the bottom edge did not scroll the list: #{result.inspect}"
    assert_equal 0, result["stillWhileMiddle"], "the list kept scrolling with the pointer away from the edges"

    moved_to = nil
    deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + Capybara.default_max_wait_time
    loop do
      moved_to = @user.family.rules.ordered.pluck(:id).index(rules.first.id)
      break if moved_to.positive? || Process.clock_gettime(Process::CLOCK_MONOTONIC) > deadline
      sleep 0.05
    end
    assert_operator moved_to, :>=, result["visibleRows"], "the rule was not dropped below the rows that were on screen"
  end

  # The rows move under a pointer that may not move at all; the drop position
  # has to follow them without waiting for the next pointer event.
  test "the drop position follows the rows as the list scrolls under a still pointer" do
    # Tall enough that the pointer at the bottom edge isn't over the dragged
    # (first) row itself, where no drop position shows.
    page.driver.browser.manage.window.resize_to(1200, 1000)
    rules = 30.times.map do |index|
      @user.family.rules.create!(name: "Rule #{format('%02d', index)}", resource_type: "transaction",
        actions: [ Rule::Action.new(action_type: "exclude_transaction") ])
    end
    sign_in @user
    visit rules_path
    first = "[data-sortable-list-id='rule:#{rules.first.id}']"
    assert_selector first

    result = page.evaluate_async_script(<<~JS, first)
      const [sourceSelector] = arguments;
      const done = arguments[arguments.length - 1];
      const source = document.querySelector(sourceSelector);
      let main = document.scrollingElement;
      for (let node = source.parentElement; node; node = node.parentElement) {
        if (/auto|scroll/.test(getComputedStyle(node).overflowY) && node.scrollHeight > node.clientHeight) { main = node; break; }
      }
      const box = main.getBoundingClientRect();
      const y = Math.min(box.bottom, window.innerHeight) - 8;
      const x = box.left + box.width / 2;
      const dataTransfer = new DataTransfer();
      const fire = (element, type) => element.dispatchEvent(new DragEvent(type,
        { bubbles: true, cancelable: true, dataTransfer, clientX: x, clientY: y }));
      const marked = () => document.querySelector("[data-sortable-list-target='item'].border-primary");

      fire(source, "dragstart");
      // On the list itself (its dragover handler) and so the page's too.
      fire(source.closest("[data-controller~='sortable-list']"), "dragover");
      const first = marked();
      // No further pointer events: only the scrolling moves the rows.
      setTimeout(() => {
        const now = marked();
        // The slot a fresh pointer event would show at the same point (the
        // first row whose centre is below it, which may sit half a row lower).
        const list = source.closest("[data-controller~='sortable-list']");
        const expected = window.Stimulus.getControllerForElementAndIdentifier(list, "sortable-list").dropSlot(x, y)?.element;
        fire(source, "dragend");
        done({
          firstId: first?.dataset.sortableListId, nowId: now?.dataset.sortableListId,
          expectedId: expected?.dataset.sortableListId
        });
      }, 600);
    JS

    assert result["firstId"], "the first dragover showed no drop position: #{result.inspect}"
    assert_not_equal result["firstId"], result["nowId"], "the drop position stayed on a row that scrolled away"
    assert_equal result["expectedId"], result["nowId"], "the drop position is not where the pointer now is: #{result.inspect}"
  end

  test "a card held still by touch at the bottom edge scrolls the page without moving" do
    sign_in @user
    assert_selector "[data-section-key]", minimum: 2

    result = page.evaluate_async_script(<<~JS)
      const done = arguments[arguments.length - 1];
      const card = document.querySelector("section[data-section-key]");
      let main = document.scrollingElement;
      for (let node = card.parentElement; node; node = node.parentElement) {
        if (/auto|scroll/.test(getComputedStyle(node).overflowY) && node.scrollHeight > node.clientHeight) { main = node; break; }
      }
      const box = main.getBoundingClientRect();
      const y = Math.min(box.bottom, window.innerHeight) - 8;
      const x = box.left + box.width / 2;
      // The touch is dispatched on a card (the second one, scrolled so that
      // its top sits just above the point), at a point in the bottom edge.
      const held = document.querySelectorAll("section[data-section-key]")[1];
      main.scrollTop += held.getBoundingClientRect().top - (y - 30);
      const touches = [ new Touch({ identifier: 1, target: held, clientX: x, clientY: y }) ];
      const before = main.scrollTop;

      held.dispatchEvent(new TouchEvent("touchstart", { bubbles: true, cancelable: true, touches, changedTouches: touches }));
      // Past the 800 ms hold, with no touchmove at all.
      setTimeout(() => {
        const scrolled = main.scrollTop - before;
        held.dispatchEvent(new TouchEvent("touchend", { bubbles: true, cancelable: true, touches: [], changedTouches: touches }));
        done({ scrolled });
      }, 1500);
    JS

    assert_operator result["scrolled"], :>, 50, "a card held still at the edge did not scroll: #{result.inspect}"
  ensure
    page.execute_script("localStorage.clear()") rescue nil
  end

  test "a card held by touch near the bottom edge scrolls the page until the finger lifts" do
    sign_in @user
    assert_selector "[data-section-key]", minimum: 2

    result = page.evaluate_async_script(<<~JS)
      const done = arguments[arguments.length - 1];
      // The box that scrolls the list (the rules page's layout scrolls an
      // inner column, the dashboard #main).
      const scrollerOf = (element) => {
        for (let node = element.parentElement; node; node = node.parentElement) {
          if (/auto|scroll/.test(getComputedStyle(node).overflowY) && node.scrollHeight > node.clientHeight) return node;
        }
        return document.scrollingElement;
      };
      const card = document.querySelector("section[data-section-key]");
      const main = scrollerOf(card);
      const box = main.getBoundingClientRect();
      const bottom = Math.min(box.bottom, window.innerHeight);
      const start = card.getBoundingClientRect();
      const touch = (y) => new Touch({ identifier: 1, target: card, clientX: start.left + 20, clientY: y });
      const fire = (type, touches) =>
        card.dispatchEvent(new TouchEvent(type, { bubbles: true, cancelable: true, touches, changedTouches: touches }));

      fire("touchstart", [touch(start.top + 20)]);
      // Past the dashboard's 800 ms hold, so the card is picked up.
      setTimeout(() => {
        const before = main.scrollTop;
        fire("touchmove", [touch(bottom - 8)]);
        setTimeout(() => {
          const scrolled = main.scrollTop - before;
          fire("touchend", []);
          const lifted = main.scrollTop;
          setTimeout(() => done({ scrolled, afterLift: main.scrollTop - lifted }), 300);
        }, 700);
      }, 1000);
    JS

    assert_operator result["scrolled"], :>, 100, "holding a card at the bottom edge did not scroll: #{result.inspect}"
    assert_operator result["afterLift"], :<=, 20, "the page kept scrolling after the finger lifted"
  ensure
    page.execute_script("localStorage.clear()") rescue nil
  end
end
