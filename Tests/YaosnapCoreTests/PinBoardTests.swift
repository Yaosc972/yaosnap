import Testing
@testable import YaosnapCore

struct PinBoardTests {
    @Test func defaultGroupIsActive() {
        let board = PinBoard()
        #expect(board.groups.count == 1)
        #expect(board.groups[0].id == PinBoard.defaultGroupID)
        #expect(board.groups[0].name == "默认")
        #expect(board.groups[0].isDefault)
        #expect(board.activeGroupID == PinBoard.defaultGroupID)
        #expect(board.soloPinID == nil)
    }

    @Test func addGroupTrimsNameAndRejectsEmptyOrDuplicate() {
        var board = PinBoard()
        let blank = board.addGroup(named: "  ")
        let work = board.addGroup(named: " 工作 ")
        #expect(blank == nil)
        #expect(work != nil)
        #expect(board.groups.last?.name == "工作")
        let duplicate = board.addGroup(named: "工作")
        #expect(duplicate == nil)
        #expect(board.groups.count == 2)
    }

    @Test func renameGroupRejectsEmptyDuplicateAndUnknown() {
        var board = PinBoard()
        guard let work = board.addGroup(named: "工作") else {
            Issue.record("建组失败")
            return
        }
        let renamed = board.renameGroup(id: work, to: "资料")
        #expect(renamed)
        #expect(board.group(id: work)?.name == "资料")
        let defaultName = board.renameGroup(id: work, to: "默认")
        let blankName = board.renameGroup(id: work, to: "  ")
        let unknownGroup = board.renameGroup(id: 99, to: "其他")
        #expect(!defaultName)
        #expect(!blankName)
        #expect(!unknownGroup)
    }

    @Test func deletingGroupMovesItsPinsToDefault() {
        var board = PinBoard()
        guard let work = board.addGroup(named: "工作") else {
            Issue.record("建组失败")
            return
        }
        board.assign(pinID: 1, toGroup: PinBoard.defaultGroupID)
        board.assign(pinID: 2, toGroup: work)
        board.assign(pinID: 3, toGroup: work)
        #expect(board.pins(inGroup: work) == [2, 3])

        let moved = board.deleteGroup(id: work)
        #expect(moved == [2, 3])
        #expect(board.groupID(of: 2) == PinBoard.defaultGroupID)
        #expect(board.groupID(of: 3) == PinBoard.defaultGroupID)
        #expect(board.group(id: work) == nil)
    }

    @Test func defaultGroupCannotBeDeletedAndActiveGroupFallsBack() {
        var board = PinBoard()
        guard let work = board.addGroup(named: "工作") else {
            Issue.record("建组失败")
            return
        }
        let deletedDefault = board.deleteGroup(id: PinBoard.defaultGroupID)
        #expect(deletedDefault.isEmpty)
        #expect(board.groups.contains { $0.id == PinBoard.defaultGroupID })

        let activated = board.activateGroup(id: work)
        #expect(activated)
        let deletedActive = board.deleteGroup(id: work)
        #expect(deletedActive.isEmpty)
        #expect(board.activeGroupID == PinBoard.defaultGroupID)
    }

    @Test func onlyActiveGroupPinsAreVisible() {
        var board = PinBoard()
        guard let work = board.addGroup(named: "工作") else {
            Issue.record("建组失败")
            return
        }
        board.assign(pinID: 1, toGroup: PinBoard.defaultGroupID)
        board.assign(pinID: 2, toGroup: work)
        #expect(board.shouldShow(pinID: 1))
        #expect(!board.shouldShow(pinID: 2))

        let activated = board.activateGroup(id: work)
        #expect(activated)
        #expect(!board.shouldShow(pinID: 1))
        #expect(board.shouldShow(pinID: 2))

        let unknown = board.activateGroup(id: 99)
        #expect(!unknown)
        #expect(board.activeGroupID == work)
    }

    @Test func switchingGroupExitsSolo() {
        var board = PinBoard()
        guard let work = board.addGroup(named: "工作") else {
            Issue.record("建组失败")
            return
        }
        board.assign(pinID: 1, toGroup: PinBoard.defaultGroupID)
        let started = board.beginSolo(pinID: 1)
        #expect(started)
        let activated = board.activateGroup(id: work)
        #expect(activated)
        #expect(board.soloPinID == nil)
        #expect(!board.shouldShow(pinID: 1))
    }

    @Test func soloShowsOnlyThatPinThenGroupViewReturns() {
        var board = PinBoard()
        guard let work = board.addGroup(named: "工作") else {
            Issue.record("建组失败")
            return
        }
        board.assign(pinID: 1, toGroup: PinBoard.defaultGroupID)
        board.assign(pinID: 2, toGroup: PinBoard.defaultGroupID)
        board.assign(pinID: 3, toGroup: work)

        let started = board.beginSolo(pinID: 2)
        #expect(started)
        #expect(board.soloPinID == 2)
        #expect(!board.shouldShow(pinID: 1))
        #expect(board.shouldShow(pinID: 2))
        #expect(!board.shouldShow(pinID: 3))

        let ended = board.endSolo()
        #expect(ended)
        #expect(board.soloPinID == nil)
        #expect(board.shouldShow(pinID: 1))
        #expect(board.shouldShow(pinID: 2))
        #expect(!board.shouldShow(pinID: 3))
    }

    @Test func soloIsUniqueAndRejectsUnknownPin() {
        var board = PinBoard()
        board.assign(pinID: 1, toGroup: PinBoard.defaultGroupID)
        board.assign(pinID: 2, toGroup: PinBoard.defaultGroupID)

        let first = board.beginSolo(pinID: 1)
        let started = board.beginSolo(pinID: 2)
        #expect(first)
        #expect(started)
        #expect(board.soloPinID == 2)
        #expect(!board.shouldShow(pinID: 1))

        let unknown = board.beginSolo(pinID: 99)
        #expect(!unknown)
        #expect(board.soloPinID == 2)
    }

    @Test func forgetRemovesPinAndClearsSolo() {
        var board = PinBoard()
        board.assign(pinID: 1, toGroup: PinBoard.defaultGroupID)
        let started = board.beginSolo(pinID: 1)
        #expect(started)

        board.forget(pinID: 1)
        #expect(board.soloPinID == nil)
        #expect(board.pins(inGroup: PinBoard.defaultGroupID).isEmpty)
        #expect(board.groupID(of: 1) == PinBoard.defaultGroupID)
    }
}
