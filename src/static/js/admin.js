var admin = angular.module('admin', ['ngResource', 'ngCookies']);

admin.factory('Stream', function($resource){
    return $resource('/stream/:id', {'id': '@id'});
});

admin.controller('StreamsCtrl', function($scope, Stream){
    $scope.searchText = '';

    Stream.query(function(streams){
        $scope.streams = streams;
    });
});