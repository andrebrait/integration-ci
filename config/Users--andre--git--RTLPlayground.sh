# integration config for /Users/andre/git/RTLPlayground
FORK_REMOTE=fork
UPSTREAM=logicog/RTLPlayground
BRANCH=integration/switches
BASE=upstream/main
UPSTREAM_MAIN_REF=upstream/main

# Third-party carries and fork-only drafts; original upstream heads are never rewritten.
# 615 includes our SNMP followups/UI; its integration-only RX/space adaptation
# lives in fixups/Users--andre--git--RTLPlayground/615-*.patch.
EXTRA_PRS='587=carry/pr-587 588=carry/pr-588 589=carry/pr-589 590=carry/pr-590 592=carry/pr-592 593=carry/pr-593 600=carry/pr-600 605=carry/pr-605 615=carry/pr-615 651=carry/pr-651 660=carry/pr-660 661=carry/pr-661 andrebrait/RTLPlayground#1=feat/lldp-linkdown-forget andrebrait/RTLPlayground#2=feat/lldp-nb-sysdesc andrebrait/RTLPlayground#3=feat/lldp-tlv-switches andrebrait/RTLPlayground#4=feat/lldp-warning-details'

# Our 588 carry deliberately composes 590 + 600 + 588 as one TX chain,
# unlike the independent upstream 588 head; each squash contributes only its diff.
# 661 carries both RJ45 and SFP CSS commits, on 660's status initialization fix.
STACKED_PRS='589:587 592:589 593:592 605:593 600:590 588:600 661:660 andrebrait/RTLPlayground#1:589 andrebrait/RTLPlayground#2:593 andrebrait/RTLPlayground#3:588 andrebrait/RTLPlayground#4:605'

# No build, test, CI dispatch, or deployment hooks: firmware is built manually.
