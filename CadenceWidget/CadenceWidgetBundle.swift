//
//  CadenceWidgetBundle.swift
//  CadenceWidget
//

import SwiftUI
import WidgetKit

@main
struct CadenceWidgetBundle: WidgetBundle {
    var body: some Widget {
        TodayWidget()
        UpNextWidget()
    }
}
